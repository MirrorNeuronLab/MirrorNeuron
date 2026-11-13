defmodule MirrorNeuron.Persistence.RedisStore.ArchiveTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob

  test "archiving terminal DockerWorker and DockerCompose jobs retains their runs" do
    suffix = System.unique_integer([:positive])

    jobs = [
      {"archive-worker-#{suffix}", %{"runner_module" => "MirrorNeuron.Runner.DockerWorker"}},
      {"archive-compose-#{suffix}",
       %{
         "runner_module" => "MirrorNeuron.Runner.DockerCompose",
         "mn_docker_compose" => %{"project_name" => "mn-compose-archive"}
       }}
    ]

    on_exit(fn ->
      Enum.each(jobs, fn {job_id, _config} ->
        _ = RedisStore.delete_job("run-#{job_id}")
        _ = RedisStore.delete_job_definition(job_id)
      end)
    end)

    for {job_id, config} <- jobs do
      run_id = "run-#{job_id}"

      assert {:ok, _definition} =
               RedisStore.persist_job_definition(job_id, %{
                 "job_id" => job_id,
                 "status" => "active",
                 "run_ids" => [run_id],
                 "manifest" => %{"flow" => %{"nodes" => [%{"config" => config}]}}
               })

      assert {:ok, _run} =
               RedisStore.persist_terminal_job(run_id, %{
                 "job_id" => run_id,
                 "stable_job_id" => job_id,
                 "status" => "completed"
               })

      assert {:ok, archived} = StableJob.archive(job_id)
      assert archived["status"] == "archived"
      assert {:ok, %{"status" => "completed"}} = RedisStore.fetch_job(run_id)
    end
  end

  test "conditional job update restores an archive without restarting retained runs" do
    job_id = "restore-archive-#{System.unique_integer([:positive])}"
    run_id = "run-#{job_id}"

    definition = %{
      "job_id" => job_id,
      "status" => "archived",
      "revision" => 3,
      "run_ids" => [run_id],
      "latest_run_id" => run_id,
      "data_generation" => 4,
      "resolved_configuration" => %{"mode" => "saved"},
      "schedules" => [%{"status" => "paused"}],
      "manifest" => %{"flow" => %{"nodes" => []}}
    }

    on_exit(fn ->
      RedisStore.delete_job(run_id)
      RedisStore.delete_job_definition(job_id)
    end)

    assert {:ok, _} = RedisStore.persist_job_definition(job_id, definition)

    assert {:ok, _} =
             RedisStore.persist_terminal_job(run_id, %{
               "job_id" => run_id,
               "stable_job_id" => job_id,
               "status" => "completed"
             })

    assert {:error, :revision_mismatch} =
             StableJob.update(job_id, %{"status" => "active"}, expected_revision: 2)

    assert {:ok, restored} =
             StableJob.update(job_id, %{"status" => "active"}, expected_revision: 3)

    assert restored["status"] == "active"
    assert restored["revision"] == 4

    for key <- ~w(job_id run_ids latest_run_id data_generation resolved_configuration schedules) do
      assert restored[key] == definition[key]
    end

    assert {:ok, %{"status" => "active"}} = StableJob.get(job_id)
    assert {:ok, %{"status" => "completed"}} = RedisStore.fetch_job(run_id)

    assert {:error, :invalid_job_update} =
             StableJob.update(job_id, %{"status" => "archived"}, expected_revision: 4)
  end

  test "archive reclaims a start gate left by a terminated local caller" do
    job_id = "stale-start-gate-#{System.unique_integer([:positive])}"
    lease_name = "job-data-start:#{job_id}"

    holder =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    holder_ref = Process.monitor(holder)
    owner_id = "#{NodeAdapter.self()}:#{inspect(holder)}:1"

    on_exit(fn ->
      _ = RedisStore.delete_job_definition(job_id)
    end)

    assert {:ok, _definition} =
             RedisStore.persist_job_definition(job_id, %{
               "job_id" => job_id,
               "status" => "active",
               "run_ids" => [],
               "manifest" => %{"flow" => %{"nodes" => []}}
             })

    assert {:ok, stale_lease} = RedisStore.acquire_fenced_lease(lease_name, owner_id, 600_000)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, :killed}

    assert {:ok, archived} = StableJob.archive(job_id)
    assert archived["status"] == "archived"

    assert {:error, :not_owner} =
             RedisStore.release_fenced_lease(lease_name, owner_id, stale_lease["epoch"])
  end
end
