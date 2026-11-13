defmodule MirrorNeuron.Execution.LeaseManager.IsolationTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Execution.LeaseManager

  test "a saturated pool does not delay another pool" do
    manager =
      start_supervised!({LeaseManager, name: nil, capacities: %{"slow" => 1, "fast" => 1}})

    assert {:ok, held} = LeaseManager.acquire(manager, "slow", 1)
    waiting = Task.async(fn -> LeaseManager.acquire(manager, "slow", 1) end)

    try do
      await_queued(manager, "slow", 1)
      assert {:ok, fast} = LeaseManager.acquire(manager, "fast", 1)
      assert fast["pool"] == "fast"
      LeaseManager.release(manager, fast["lease_id"])
    after
      LeaseManager.release(manager, held["lease_id"])
      Task.await(waiting)
    end
  end

  test "duplicate release cannot free another live lease" do
    manager = start_supervised!({LeaseManager, name: nil, capacities: %{"default" => 2}})
    assert {:ok, first} = LeaseManager.acquire(manager, "default", 1)
    assert {:ok, second} = LeaseManager.acquire(manager, "default", 1)
    LeaseManager.release(manager, first["lease_id"])
    LeaseManager.release(manager, first["lease_id"])
    assert %{"default" => %{in_use: 1, active: 1, available: 1}} = LeaseManager.stats(manager)
    LeaseManager.release(manager, second["lease_id"])
  end

  test "a queued caller exit frees its queue slot without changing active capacity" do
    manager =
      start_supervised!(
        {LeaseManager, name: nil, capacities: %{"default" => 1}, max_queue_length: 1}
      )

    assert {:ok, held} = LeaseManager.acquire(manager, "default", 1)
    {caller, monitor} = spawn_monitor(fn -> LeaseManager.acquire(manager, "default", 1) end)

    try do
      await_queued(manager, "default", 1)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
      await_queued(manager, "default", 0)
      assert %{"default" => %{in_use: 1, active: 1}} = LeaseManager.stats(manager)
    after
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      LeaseManager.release(manager, held["lease_id"])
    end
  end

  defp await_queued(manager, pool, expected, attempts \\ 100) do
    actual = LeaseManager.stats(manager)[pool].queued

    if actual != expected and attempts > 0 do
      Process.sleep(5)
      await_queued(manager, pool, expected, attempts - 1)
    else
      assert actual == expected
    end
  end
end
