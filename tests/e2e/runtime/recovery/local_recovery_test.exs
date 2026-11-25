defmodule MirrorNeuron.Runtime.LocalRecovery.ScanTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.LocalRecovery

  setup do
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_wait_replicas = Application.get_env(:mirror_neuron, :redis_wait_replicas)

    namespace = "local_recovery_test_#{System.unique_integer([:positive])}"

    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    Application.put_env(:mirror_neuron, :redis_wait_replicas, 0)
    System.put_env("MN_REDIS_NAMESPACE", namespace)

    on_exit(fn ->
      cleanup_namespace(namespace)
      restore_env(:redis_namespace, old_namespace)
      restore_env(:redis_wait_replicas, old_wait_replicas)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
    end)

    {:ok, namespace: namespace}
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

  test "periodic recovery retries startup index repair after Redis becomes readable", %{
    namespace: namespace
  } do
    MirrorNeuron.RedisStoreCase.suspend_process(LocalRecovery)

    scanner =
      start_supervised!(
        {LocalRecovery, name: nil, startup_delay_ms: 60_000, scan_interval_ms: 60_000}
      )

    job_id = "retained-run"
    key = "#{namespace}:jobs"

    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{"job_id" => job_id, "status" => "completed"})

    # Keep the durable job but make the index temporarily unreadable as a set.
    assert {:ok, "OK"} = Redix.command(MirrorNeuron.Redis.Connection, ["SET", key, "unavailable"])
    send(scanner, :scan)
    assert :sys.get_state(scanner).repair_indexes_on_next_scan

    assert {:ok, 1} = Redix.command(MirrorNeuron.Redis.Connection, ["DEL", key])
    send(scanner, :scan)
    refute :sys.get_state(scanner).repair_indexes_on_next_scan
    assert {:ok, [^job_id]} = RedisStore.list_job_ids()
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
