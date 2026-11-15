defmodule MirrorNeuron.Runtime.StableJobArchiveTest do
  use MirrorNeuron.RuntimeCase, async: false

  alias MirrorNeuron.Persistence.{CancellationStore, RedisStore}
  alias MirrorNeuron.Runtime.{NodeAdmission, StableJob}
  alias MirrorNeuron.Runtime.StableJob.RunCleanup
  alias Mirrorneuron.Cluster.V1.SetResourceResponse

  setup %{id: id} do
    previous = Application.get_env(:mirror_neuron, :native_sdk_grpc_native_resource_client)
    parent = self()
    failure = start_supervised!({Agent, fn -> false end})

    Application.put_env(:mirror_neuron, :native_sdk_grpc_native_resource_client, fn _,
                                                                                    request,
                                                                                    _ ->
      attrs = Jason.decode!(request.resource_json)
      send(parent, {:native_command, attrs})

      errors =
        if Agent.get(failure, & &1) && attrs["operation"] == "cleanup",
          do: ["owned resource is still busy"],
          else: []

      {:ok, %SetResourceResponse{resource_json: Jason.encode!(%{"errors" => errors}), version: 1}}
    end)

    on_exit(fn ->
      Application.put_env(:mirror_neuron, :native_sdk_grpc_native_resource_client, previous)
    end)

    run_id = "run-#{id}"

    assert {:ok, _} =
             RedisStore.persist_terminal_job(run_id, %{
               "job_id" => run_id,
               "stable_job_id" => id,
               "status" => "failed"
             })

    assert {:ok, _} =
             RedisStore.persist_job_definition(id, %{
               "job_id" => id,
               "owner_node" => to_string(Node.self()),
               "status" => "active",
               "revision" => 3,
               "run_ids" => [run_id],
               "latest_run_id" => run_id,
               "manifest" => %{
                 "flow" => %{"nodes" => []},
                 "metadata" => %{
                   "mn_native_resources" => %{
                     "resources" => [
                       %{
                         "kind" => "docker_compose",
                         "external_id" => "owned-#{id}",
                         "owner_node" => to_string(Node.self())
                       }
                     ]
                   }
                 }
               }
             })

    {:ok, run_id: run_id, failure: failure}
  end

  test "archive retires definition resources before acknowledging, retaining history", %{
    id: id,
    run_id: run_id
  } do
    assert {:ok, _} =
             NodeAdmission.reserve(
               %{
                 "job_id" => run_id,
                 "stable_job_id" => id,
                 "manifest" => %{},
                 "submitted_at" => MirrorNeuron.Runtime.timestamp()
               },
               "start_now"
             )

    assert NodeAdmission.claimed?(run_id)
    assert {:ok, archived} = StableJob.archive(id, expected_revision: 3)
    refute NodeAdmission.claimed?(run_id)
    assert archived["status"] == "archived"
    assert archived["revision"] == 4

    assert_receive {:native_command,
                    %{
                      "operation" => "cleanup",
                      "external_ids" => [external],
                      "resource_kinds" => ["docker_compose"]
                    }}

    assert external == "owned-#{id}"
    assert_receive {:native_command, %{"operation" => "cleanup", "job_id" => ^id}}
    assert {:ok, %{"status" => "failed"}} = RedisStore.fetch_job(run_id)
    assert archived["run_ids"] == [run_id]
  end

  test "failed cleanup does not acknowledge archive and can be retried", %{
    id: id,
    failure: failure
  } do
    Agent.update(failure, fn _ -> true end)
    assert {:error, _} = StableJob.archive(id, expected_revision: 3)
    assert {:ok, %{"status" => "active", "revision" => 3}} = StableJob.get(id)
    Agent.update(failure, fn _ -> false end)

    assert {:ok, %{"status" => "archived", "revision" => 4}} =
             StableJob.archive(id, expected_revision: 3)
  end

  test "an already archived definition still reconciles cleanup without changing revision", %{
    id: id
  } do
    assert {:ok, job} = StableJob.get(id)
    assert {:ok, _} = RedisStore.persist_job_definition(id, Map.put(job, "status", "archived"))

    assert {:ok, %{"status" => "archived", "revision" => 3}} =
             StableJob.archive(id, expected_revision: 3)

    assert_receive {:native_command, %{"operation" => "cleanup", "external_ids" => [_]}}
  end

  for status <- ~w(pending queued running paused) do
    test "archive cancels a #{status} run even without its coordinator, retaining both histories",
         %{
           id: id,
           run_id: history_id
         } do
      active_id = attach_active_run(id, unquote(status))

      assert {:ok, archived} = StableJob.archive(id, expected_revision: 3)
      assert archived["status"] == "archived"
      assert archived["run_ids"] == [history_id, active_id]
      assert archived["latest_run_id"] == active_id
      assert {:ok, %{"status" => "cancelled"}} = RedisStore.fetch_job(active_id)
      assert {:ok, %{"status" => "failed"}} = RedisStore.fetch_job(history_id)
      assert {:ok, %{"status" => "acknowledged"}} = CancellationStore.fetch(active_id)
    end
  end

  test "archive waits for durable run cleanup before retiring the definition", %{
    id: id,
    failure: failure
  } do
    active_id = attach_active_run(id, "running")
    Agent.update(failure, fn _ -> true end)
    task = Task.async(fn -> StableJob.archive(id, expected_revision: 3) end)

    assert_receive {:native_command, %{"operation" => "cleanup", "job_id" => ^active_id}}, 2_000
    assert Task.yield(task, 0) == nil
    assert {:ok, %{"status" => "active"}} = StableJob.get(id)
    refute_receive {:native_command, %{"external_ids" => [_]}}

    Agent.update(failure, fn _ -> false end)
    MirrorNeuron.Runtime.CancellationReconciler.reconcile_now(active_id)
    assert {:ok, %{"status" => "archived"}} = Task.await(task, 5_000)
  end

  test "an unconfirmed cancellation stays unarchived and retry reuses its durable intent", %{
    id: id,
    failure: failure
  } do
    active_id = attach_active_run(id, "running")
    Agent.update(failure, fn _ -> true end)
    assert {:ok, definition} = StableJob.get(id)

    assert {:error, {:run_cleanup_failed, ^active_id, _}} =
             RunCleanup.stop_runs_for_archive(definition, 0)

    assert {:ok, %{"status" => "active", "revision" => 3}} = StableJob.get(id)
    assert {:ok, cancellation} = CancellationStore.fetch(active_id)
    Agent.update(failure, fn _ -> false end)
    assert {:ok, %{"status" => "archived"}} = StableJob.archive(id, expected_revision: 3)
    assert {:ok, retried} = CancellationStore.fetch(active_id)
    assert retried["request_id"] == cancellation["request_id"]
  end

  test "a stale revision cannot cancel active work", %{id: id} do
    active_id = attach_active_run(id, "running")
    assert {:error, _} = StableJob.archive(id, expected_revision: 2)
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(active_id)
    assert {:error, _} = CancellationStore.fetch(active_id)
    refute_receive {:native_command, _}
  end

  test "Job API archive stops all attached runs and preserves their public blueprint IDs", %{
    id: id
  } do
    alias MirrorNeuron.Grpc.Handlers.Job.{Definitions, Runs}
    alias Mirrorneuron.Job.V1.{JobRequest, RunRequest}

    running = attach_active_run(id, "running")
    paused = attach_active_run(id, "paused")
    unrelated = "unrelated-#{id}"

    assert {:ok, _} =
             RedisStore.persist_job(unrelated, %{"job_id" => unrelated, "status" => "running"})

    response = Definitions.archive_job(%JobRequest{job_id: id, expected_revision: 3}, nil)
    assert Jason.decode!(response.result_json)["status"] == "archived"
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(unrelated)
    listed = Runs.list_runs(%JobRequest{job_id: id, page_size: 50}, nil)
    items = Jason.decode!(listed.result_json)["items"]

    for run_id <- [running, paused] do
      assert %{"blueprint_id" => "cctv_operator", "status" => "cancelled"} =
               Enum.find(items, &(&1["run_id"] == run_id))

      detail = Runs.get_run(%RunRequest{run_id: run_id}, nil)
      assert Jason.decode!(detail.result_json)["blueprint_id"] == "cctv_operator"
    end
  end

  defp attach_active_run(id, status) do
    run_id = "#{status}-#{id}"

    assert {:ok, _} =
             RedisStore.persist_job(run_id, %{
               "job_id" => run_id,
               "stable_job_id" => id,
               "status" => status,
               "graph_id" => "cctv_operator",
               "manifest" => %{"metadata" => %{"blueprint_id" => "cctv_operator"}}
             })

    assert {:ok, definition} = StableJob.get(id)

    assert {:ok, _} =
             RedisStore.persist_job_definition(
               id,
               definition
               |> Map.update!("run_ids", &(&1 ++ [run_id]))
               |> Map.put("latest_run_id", run_id)
             )

    run_id
  end
end
