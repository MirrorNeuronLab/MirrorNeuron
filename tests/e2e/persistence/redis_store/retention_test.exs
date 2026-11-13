defmodule MirrorNeuron.Persistence.RedisStore.RetentionTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Artifacts.JobStore
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.RedisStoreCase.CleanupNodeAdapterStub

  test "retention sweep deletes expired terminal jobs and stale job ids" do
    job_id = "terminal-retention-#{System.unique_integer([:positive])}"
    old_job_root = System.get_env("MN_JOB_ARTIFACT_ROOT")

    job_root =
      Path.join(System.tmp_dir!(), "mn_job_artifacts_#{System.unique_integer([:positive])}")

    System.put_env("MN_JOB_ARTIFACT_ROOT", job_root)

    on_exit(fn ->
      restore_system_env("MN_JOB_ARTIFACT_ROOT", old_job_root)
      File.rm_rf(job_root)
    end)

    assert {:ok, job_path} = JobStore.ensure_job_dir(job_id)
    File.write!(Path.join(job_path, "artifact.txt"), "done")

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(job_id, %{"status" => "completed"}, %{
               "graph_id" => "retention_test",
               "job_name" => "retention_test"
             })

    assert {:ok, _job} = RedisStore.fetch_job(job_id)

    assert {:ok, result} = RedisStore.sweep_retention(terminal_job_ttl_seconds: 0)
    assert result.deleted_jobs == [job_id]
    assert result.deleted_count == 1
    assert {:error, _reason} = RedisStore.fetch_job(job_id)
    refute File.exists?(job_path)
  end

  test "retention preserves terminal state when resource cleanup fails" do
    job_id = "deferred-terminal-retention-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(job_id, %{"status" => "completed"}, %{
               "graph_id" => "deferred_retention",
               "job_name" => "deferred retention"
             })

    assert {:ok, result} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: fn ^job_id -> {:error, :resource_busy} end
             )

    refute job_id in result.deleted_jobs
    assert {:ok, %{"status" => "completed"}} = RedisStore.fetch_job(job_id)

    RedisStore.delete_job(job_id)
  end

  test "retention does not clean jobs whose persisted state is unreadable", %{
    namespace: namespace
  } do
    job_id = "unreadable-retention-job-#{System.unique_integer([:positive])}"
    parent = self()

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id]),
               "not-json"
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               job_id
             ])

    assert {:ok, result} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: fn cleanup_job_id, _job ->
                 send(parent, {:cleanup_called, cleanup_job_id})
                 :ok
               end
             )

    refute_receive {:cleanup_called, ^job_id}
    refute job_id in result.stale_job_ids

    assert {:ok, "not-json"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["job", job_id])
             ])
  end

  test "job deletion retains the record when shared storage cannot be removed safely" do
    job_id = "failed-resource-cleanup-#{System.unique_integer([:positive])}"
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    old_artifact_root = System.get_env("MN_JOB_ARTIFACT_ROOT")

    test_root =
      Path.join(System.tmp_dir!(), "mn_failed_cleanup_#{System.unique_integer([:positive])}")

    shared_root = Path.join(test_root, "shared")
    artifact_root = Path.join(test_root, "artifacts")
    outside_submission = Path.join(test_root, "outside-submission")

    File.mkdir_p!(shared_root)
    File.mkdir_p!(outside_submission)
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)
    System.put_env("MN_JOB_ARTIFACT_ROOT", artifact_root)

    on_exit(fn ->
      case RedisStore.fetch_job(job_id) do
        {:ok, job} ->
          _ = RedisStore.persist_job(job_id, Map.put(job, "manifest", %{}))
          _ = RedisStore.delete_job(job_id)

        _other ->
          :ok
      end

      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
      restore_system_env("MN_JOB_ARTIFACT_ROOT", old_artifact_root)
      File.rm_rf(test_root)
    end)

    assert {:ok, artifact_path} = JobStore.ensure_job_dir(job_id)
    File.write!(Path.join(artifact_path, "result.txt"), "remove with terminal job record")

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(job_id, %{
               "status" => "completed",
               "manifest" => %{
                 "metadata" => %{
                   "mn_storage" => %{"submission_path" => outside_submission}
                 }
               }
             })

    assert {:error, "mn_storage.submission_path is outside shared storage root"} =
             RedisStore.delete_job(job_id)

    assert {:ok, _job} = RedisStore.fetch_job(job_id)
    assert File.exists?(artifact_path)
    assert File.dir?(outside_submission)
  end

  test "retention retries sandbox cleanup on disconnected persisted placement nodes" do
    job_id = "disconnected-sandbox-retention-#{System.unique_integer([:positive])}"
    remote_node = :"cleanup-worker@lab"
    old_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)

    assert {:ok, job} =
             RedisStore.persist_terminal_job(job_id, %{
               "status" => "completed",
               "scheduler" => %{
                 "placements" => [%{"agent_id" => "worker", "node" => to_string(remote_node)}]
               }
             })

    CleanupNodeAdapterStub.reset(self())
    Application.put_env(:mirror_neuron, :cluster_node_adapter, CleanupNodeAdapterStub)

    on_exit(fn ->
      restore_env(:cluster_node_adapter, old_adapter)
      RedisStore.delete_job(job_id)
    end)

    assert {:error, failures} = Runtime.cleanup_job_sandboxes(job_id, job)

    assert Enum.all?(failures, &(&1.node == to_string(remote_node)))

    assert Enum.map(failures, & &1.resource) ==
             ["runner commands", "prepared workers", "model residency"]

    assert_receive {:cleanup_rpc, ^remote_node, MirrorNeuron.Runner, :stop_commands,
                    [^job_id, :all], 15_000}

    assert {:ok, deferred} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: &Runtime.cleanup_job_sandboxes/2
             )

    refute job_id in deferred.deleted_jobs
    assert {:ok, %{"status" => "completed"}} = RedisStore.fetch_job(job_id)

    CleanupNodeAdapterStub.put_remote_result(:ok)

    assert {:ok, reclaimed} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: &Runtime.cleanup_job_sandboxes/2
             )

    assert job_id in reclaimed.deleted_jobs
    assert {:error, _reason} = RedisStore.fetch_job(job_id)
  end
end
