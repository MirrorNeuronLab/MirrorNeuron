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
