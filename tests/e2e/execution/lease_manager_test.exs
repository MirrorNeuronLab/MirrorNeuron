defmodule MirrorNeuron.Execution.LeaseManagerTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Execution.LeaseManager

  test "queues requests when pool capacity is exhausted and grants them in order" do
    manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    assert {:ok, first} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-1"})

    parent = self()

    waiting_task =
      Task.async(fn ->
        send(parent, :second_waiting_started)
        result = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-2"})
        send(parent, {:second_acquired, result})

        receive do
          :release_second -> result
        end
      end)

    assert_receive :second_waiting_started
    Process.sleep(50)

    assert %{"default" => %{"queued" => 1, "in_use" => 1}} =
             stringify_stats(LeaseManager.stats(manager))

    LeaseManager.release(manager, first["lease_id"])

    assert_receive {:second_acquired, {:ok, second}}
    assert second["queue_wait_ms"] >= 0

    assert %{"default" => %{"queued" => 0, "in_use" => 1}} =
             stringify_stats(LeaseManager.stats(manager))

    send(waiting_task.pid, :release_second)
    assert {:ok, ^second} = Task.await(waiting_task, 1_000)

    LeaseManager.release(manager, second["lease_id"])
    Process.sleep(20)

    assert %{"default" => %{"queued" => 0, "in_use" => 0, "available" => 1}} =
             stringify_stats(LeaseManager.stats(manager))
  end

  test "rejects requests for unknown pools or oversized slot counts" do
    manager =
      start_supervised!(
        {LeaseManager, name: unique_name(), capacities: %{"default" => 2, "gpu" => 1}}
      )

    assert {:error, "unknown executor pool \"memory-heavy\""} =
             LeaseManager.acquire(manager, "memory-heavy", 1, %{})

    assert {:error, "requested 3 executor slots but pool capacity is 2"} =
             LeaseManager.acquire(manager, "default", 3, %{})
  end

  test "queued requests return retry-later after their queue timeout" do
    manager =
      start_supervised!(
        {LeaseManager, name: unique_name(), capacities: %{"default" => 1}, queue_timeout_ms: 50}
      )

    assert {:ok, first} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-1"})

    assert {:error, {:retry_later, details}} =
             LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-2"})

    assert details["reason"] == "executor_pool_queue_timeout"
    assert details["pool"] == "default"
    assert details["timeout_ms"] == 50

    assert %{"default" => %{"queued" => 0, "in_use" => 1}} =
             stringify_stats(LeaseManager.stats(manager))

    LeaseManager.release(manager, first["lease_id"])
  end

  test "queue limit rejects excess requests without parking callers" do
    manager =
      start_supervised!(
        {LeaseManager,
         name: unique_name(),
         capacities: %{"default" => 1},
         queue_timeout_ms: 1_000,
         max_queue_length: 1}
      )

    assert {:ok, first} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-1"})

    parent = self()

    waiting_task =
      Task.async(fn ->
        send(parent, :waiting_started)
        LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-2"})
      end)

    assert_receive :waiting_started
    Process.sleep(20)

    assert {:error, {:retry_later, details}} =
             LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-3"})

    assert details["reason"] == "executor_pool_queue_full"
    assert details["max_queue_length"] == 1

    LeaseManager.release(manager, first["lease_id"])
    assert {:ok, _second} = Task.await(waiting_task, 1_000)
  end

  test "timed out requests behind a live waiter do not consume queue capacity" do
    manager =
      start_supervised!(
        {LeaseManager,
         name: unique_name(),
         capacities: %{"default" => 1},
         queue_timeout_ms: 1_000,
         max_queue_length: 2}
      )

    assert {:ok, first} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "active"})

    live_waiter =
      Task.async(fn ->
        LeaseManager.acquire(manager, "default", 1, %{agent_id: "live-waiter"},
          queue_timeout_ms: 1_000
        )
      end)

    Process.sleep(20)

    assert {:error, {:retry_later, %{"reason" => "executor_pool_queue_timeout"}}} =
             LeaseManager.acquire(manager, "default", 1, %{agent_id: "timed-out"},
               queue_timeout_ms: 30
             )

    assert %{"default" => %{"queued" => 1}} = stringify_stats(LeaseManager.stats(manager))

    assert {:error, {:retry_later, %{"reason" => "executor_pool_queue_timeout"}}} =
             LeaseManager.acquire(manager, "default", 1, %{agent_id: "accepted-after-timeout"},
               queue_timeout_ms: 30
             )

    LeaseManager.release(manager, first["lease_id"])
    assert {:ok, second} = Task.await(live_waiter, 1_000)
    LeaseManager.release(manager, second["lease_id"])
  end

  test "restores executor capacity when a disconnected node cannot release its lease" do
    manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    parent = self()

    owner =
      Task.async(fn ->
        assert {:ok, lease} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-1"})
        send(parent, {:lease_acquired, lease})

        receive do
          :release -> LeaseManager.release(manager, lease["lease_id"])
        end
      end)

    assert_receive {:lease_acquired, first}

    assert %{"default" => %{"in_use" => 1, "available" => 0}} =
             stringify_stats(LeaseManager.stats(manager))

    assert :ok = LeaseManager.release_node_capacity(manager, Node.self())

    assert %{"default" => %{"in_use" => 0, "available" => 1}} =
             stringify_stats(LeaseManager.stats(manager))

    assert {:ok, second} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-2"})
    assert second["lease_id"] != first["lease_id"]

    LeaseManager.release(manager, second["lease_id"])
    send(owner.pid, :release)
    assert :ok = Task.await(owner, 1_000)
  end

  test "restore capacity leaves live owners untouched" do
    manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    assert {:ok, lease} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-1"})

    assert :ok = LeaseManager.restore_capacity(manager)

    assert %{"default" => %{"in_use" => 1, "available" => 0}} =
             stringify_stats(LeaseManager.stats(manager))

    LeaseManager.release(manager, lease["lease_id"])
  end

  test "restores capacity and grants queued work after a lease owner exits" do
    manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    owner =
      Task.async(fn ->
        assert {:ok, _lease} =
                 LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-1"})

        receive do
          :stop -> :ok
        end
      end)

    Process.sleep(20)

    parent = self()

    waiting_task =
      Task.async(fn ->
        send(parent, :waiting_started)
        result = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker-2"})
        send(parent, {:queued_acquired, result})

        receive do
          :release_queued -> result
        end

        result
      end)

    assert_receive :waiting_started
    Process.sleep(20)

    assert %{"default" => %{"queued" => 1, "in_use" => 1, "available" => 0}} =
             stringify_stats(LeaseManager.stats(manager))

    send(owner.pid, :stop)
    assert :ok = Task.await(owner, 1_000)

    assert_receive {:queued_acquired, {:ok, second}}, 1_000

    assert %{"default" => %{"queued" => 0, "in_use" => 1}} =
             stringify_stats(LeaseManager.stats(manager))

    LeaseManager.release(manager, second["lease_id"])
    send(waiting_task.pid, :release_queued)
    assert {:ok, ^second} = Task.await(waiting_task, 1_000)
  end

  defp stringify_stats(stats) do
    Enum.into(stats, %{}, fn {pool, values} -> {to_string(pool), stringify_map(values)} end)
  end

  defp stringify_map(values) when is_map(values) do
    Enum.into(values, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp unique_name do
    :"lease-manager-#{System.unique_integer([:positive])}"
  end
end
