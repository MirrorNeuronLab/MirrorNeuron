defmodule MirrorNeuron.Runtime.StableJobArchiveTest do
  use MirrorNeuron.RuntimeCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{NodeAdmission, StableJob}
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
end
