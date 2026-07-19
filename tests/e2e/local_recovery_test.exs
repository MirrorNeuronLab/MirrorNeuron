defmodule MirrorNeuron.Runtime.LocalRecoveryTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.{DiskCheckpoint, RedisStore}
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.LocalRecovery

  setup do
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_checkpoint_root = System.get_env("MN_CHECKPOINT_ROOT")
    old_wait_replicas = Application.get_env(:mirror_neuron, :redis_wait_replicas)

    namespace = "local_recovery_test_#{System.unique_integer([:positive])}"

    checkpoint_root =
      Path.join(System.tmp_dir!(), "mn_local_recovery_test_#{System.unique_integer([:positive])}")

    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    Application.put_env(:mirror_neuron, :redis_wait_replicas, 0)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    System.put_env("MN_CHECKPOINT_ROOT", checkpoint_root)

    on_exit(fn ->
      cleanup_namespace(namespace)
      File.rm_rf!(checkpoint_root)
      restore_env(:redis_namespace, old_namespace)
      restore_env(:redis_wait_replicas, old_wait_replicas)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_system_env("MN_CHECKPOINT_ROOT", old_checkpoint_root)
    end)

    {:ok, namespace: namespace}
  end

  test "a disk snapshot without an agent id cannot crash the recovery scan" do
    job_id = "invalid-disk-agent-#{System.unique_integer([:positive])}"

    job = %{
      "job_id" => job_id,
      "graph_id" => "invalid_disk_agent",
      "job_name" => "invalid disk agent",
      "status" => "paused",
      "submitted_at" => Runtime.timestamp(),
      "updated_at" => Runtime.timestamp(),
      "recovery_status" => "paused_for_review",
      "recovery_requires_review" => true,
      "manifest" => %{
        "manifest_version" => "1.0",
        "graph_id" => "invalid_disk_agent",
        "entrypoints" => ["worker"],
        "flow" => %{
          "nodes" => [%{"node_id" => "worker", "agent_type" => "router"}],
          "edges" => []
        }
      }
    }

    assert :ok = DiskCheckpoint.persist_job(job_id, job)
    assert :ok = DiskCheckpoint.persist_agent(job_id, "invalid", %{})

    assert {:ok, %{checked: 1, skipped: 1, failed: 0}} =
             LocalRecovery.recover_unfinished_jobs(repair_indexes?: false)

    assert {:ok, %{"job_id" => ^job_id, "status" => "paused"}} =
             RedisStore.fetch_job(job_id)
  end

  test "periodic scan skips paused review summaries without loading full jobs", %{
    namespace: namespace
  } do
    job_id = "paused-summary-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "paused_summary",
               "status" => "paused",
               "recovery_status" => "paused_for_review",
               "recovery_requires_review" => true,
               "updated_at" => Runtime.timestamp()
             })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               "#{namespace}:job:#{job_id}"
             ])

    assert {:ok, %{checked: 1, skipped: 1, failed: 0}} =
             LocalRecovery.recover_unfinished_jobs(
               repair_indexes?: false,
               restore_disk?: false
             )
  end

  test "periodic scan skips live job runners without loading full jobs", %{
    namespace: namespace
  } do
    job_id = "live-runner-summary-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "live_runner_summary",
               "status" => "running",
               "updated_at" => Runtime.timestamp()
             })

    assert {:ok, _pid} =
             Horde.Registry.register(
               MirrorNeuron.DistributedRegistry,
               {:job_runner, job_id},
               %{}
             )

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               "#{namespace}:job:#{job_id}"
             ])

    assert {:ok, %{checked: 1, skipped: 1, failed: 0}} =
             LocalRecovery.recover_unfinished_jobs(
               repair_indexes?: false,
               restore_disk?: false
             )
  end

  test "periodic scan does not restore disk checkpoints after startup" do
    job_id = "startup-only-disk-#{System.unique_integer([:positive])}"

    assert :ok =
             DiskCheckpoint.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "startup_only_disk",
               "status" => "paused",
               "recovery_status" => "paused_for_review",
               "recovery_requires_review" => true,
               "updated_at" => Runtime.timestamp()
             })

    assert {:ok, %{checked: 0, failed: 0}} =
             LocalRecovery.recover_unfinished_jobs(
               repair_indexes?: false,
               restore_disk?: false
             )

    assert {:error, _reason} = RedisStore.fetch_job(job_id)
  end

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
