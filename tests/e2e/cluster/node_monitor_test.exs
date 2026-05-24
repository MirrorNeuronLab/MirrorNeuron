defmodule MirrorNeuron.Cluster.NodeMonitorTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.NodeMonitor
  alias MirrorNeuron.Execution.LeaseManager

  @test_pid_name :node_monitor_test_pid

  defmodule NodeStateStub do
    def advertise_self(status, attrs \\ %{}) do
      mark(Node.self(), status, attrs)
    end

    def mark(node, status, attrs \\ %{}) do
      send(Process.whereis(:node_monitor_test_pid), {:node_state_marked, node, status, attrs})
      :ok
    end
  end

  defmodule LeaderStub do
    def node_down(node) do
      send(Process.whereis(:node_monitor_test_pid), {:leader_node_down, node})
      :ok
    end
  end

  defmodule EventBusStub do
    def publish(job_id, event) do
      send(Process.whereis(:node_monitor_test_pid), {:event_published, job_id, event})
      {:ok, event}
    end
  end

  defmodule ReconcilerStub do
    def reconcile_node(node, opts) do
      send(Process.whereis(:node_monitor_test_pid), {:reconcile_node, node, opts})
      {:ok, %{checked: 2, recovered: 0, paused: 2, skipped: 0, failed: 0, jobs: []}}
    end
  end

  defmodule RedisStoreStub do
    def put_jobs(jobs), do: :persistent_term.put({__MODULE__, :jobs}, jobs)

    def list_jobs do
      {:ok, :persistent_term.get({__MODULE__, :jobs}, [])}
    end

    def persist_terminal_job(job_id, updates, defaults) do
      send(Process.whereis(:node_monitor_test_pid), {:job_persisted, job_id, updates, defaults})
      {:ok, defaults |> Map.merge(updates) |> Map.put("job_id", job_id)}
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)
    RedisStoreStub.put_jobs([])

    on_exit(fn ->
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      :persistent_term.erase({RedisStoreStub, :jobs})
    end)

    :ok
  end

  test "nodeup during reconnect cancels retries without releasing live capacity or pausing jobs" do
    manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    monitor = start_monitor(lease_manager_server: manager, reconnect_backoff_ms: 50)
    parent = self()

    owner =
      Task.async(fn ->
        assert {:ok, lease} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker"})
        send(parent, {:lease_acquired, lease})

        receive do
          :release -> LeaseManager.release(manager, lease["lease_id"])
        end
      end)

    assert_receive {:lease_acquired, lease}
    send(monitor, {:nodedown, Node.self()})
    assert_receive {:node_state_marked, _node, "reconnecting", %{}}

    send(monitor, {:nodeup, Node.self()})
    assert_receive {:node_state_marked, _node, "healthy", %{}}

    Process.sleep(75)
    refute_received {:connect_attempted, _node}
    refute_received {:job_persisted, _job_id, _updates, _defaults}
    refute_received {:leader_node_down, _node}

    assert %{"default" => %{"in_use" => 1, "available" => 0}} =
             stringify_stats(LeaseManager.stats(manager))

    LeaseManager.release(manager, lease["lease_id"])
    send(owner.pid, :release)
    assert :ok = Task.await(owner, 1_000)
  end

  test "successful reconnect keeps jobs running and queued work waits for normal capacity" do
    manager =
      start_supervised!(
        {LeaseManager,
         name: unique_name(), capacities: %{"default" => 1}, queue_timeout_ms: 1_000}
      )

    node_name = Atom.to_string(Node.self())

    RedisStoreStub.put_jobs([
      %{"job_id" => "live-job", "status" => "running", "lease_owner" => node_name}
    ])

    attempt_counter = :atomics.new(1, [])

    monitor =
      start_monitor(
        lease_manager_server: manager,
        reconnect_backoff_ms: 5,
        connect: fn node ->
          attempt = :atomics.add_get(attempt_counter, 1, 1)
          send(parent_pid(), {:connect_attempted, node, attempt})
          attempt == 2
        end
      )

    parent = self()

    owner =
      Task.async(fn ->
        assert {:ok, lease} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "owner"})
        send(parent, {:owner_acquired, lease})

        receive do
          :release_owner -> LeaseManager.release(manager, lease["lease_id"])
        end
      end)

    assert_receive {:owner_acquired, _owner_lease}

    waiting_task =
      Task.async(fn ->
        send(parent, :queued_waiting)
        result = LeaseManager.acquire(manager, "default", 1, %{agent_id: "queued"})
        send(parent, {:queued_acquired, result})

        receive do
          :release_queued -> result
        end
      end)

    assert_receive :queued_waiting

    assert_eventually(fn ->
      match?(
        %{"default" => %{"queued" => 1, "in_use" => 1}},
        stringify_stats(LeaseManager.stats(manager))
      )
    end)

    send(monitor, {:nodedown, Node.self()})
    assert_receive {:node_state_marked, _node, "reconnecting", %{}}
    assert_receive {:connect_attempted, _node, 1}, 500
    assert_receive {:connect_attempted, _node, 2}, 500
    assert_receive {:node_state_marked, _node, "healthy", %{}}

    refute_received {:job_persisted, _job_id, _updates, _defaults}
    refute_received {:event_published, "live-job", %{type: :job_paused_for_manual_restart}}
    refute_received {:leader_node_down, _node}
    refute_received {:queued_acquired, _result}

    assert %{"default" => %{"queued" => 1, "in_use" => 1, "available" => 0}} =
             stringify_stats(LeaseManager.stats(manager))

    send(owner.pid, :release_owner)
    assert :ok = Task.await(owner, 1_000)

    assert_receive {:queued_acquired, {:ok, queued_lease}}, 1_000
    assert queued_lease["metadata"]["agent_id"] == "queued"

    LeaseManager.release(manager, queued_lease["lease_id"])
    send(waiting_task.pid, :release_queued)
    assert {:ok, ^queued_lease} = Task.await(waiting_task, 1_000)
  end

  test "failed reconnect attempts release capacity and reconcile active jobs" do
    manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node_name = Atom.to_string(Node.self())

    RedisStoreStub.put_jobs([
      %{"job_id" => "running-job", "status" => "running", "lease_owner" => node_name},
      %{"job_id" => "pending-job", "status" => "pending", "lease_owner" => node_name},
      %{"job_id" => "completed-job", "status" => "completed", "lease_owner" => node_name},
      %{"job_id" => "other-job", "status" => "running", "lease_owner" => "other@test"}
    ])

    monitor =
      start_monitor(
        lease_manager_server: manager,
        reconnect_backoff_ms: 20,
        connect: fn node ->
          send(parent_pid(), {:connect_attempted, node, System.monotonic_time(:millisecond)})
          false
        end
      )

    owner =
      Task.async(fn ->
        assert {:ok, _lease} = LeaseManager.acquire(manager, "default", 1, %{agent_id: "worker"})

        receive do
          :release -> :ok
        end
      end)

    assert_eventually(fn ->
      match?(%{"default" => %{"in_use" => 1}}, stringify_stats(LeaseManager.stats(manager)))
    end)

    assert %{"default" => %{"queued" => 0, "in_use" => 1}} =
             stringify_stats(LeaseManager.stats(manager))

    send(monitor, {:nodedown, Node.self()})
    self_node = Node.self()

    attempt_timestamps =
      for _ <- 1..3 do
        assert_receive {:connect_attempted, ^self_node, timestamp}, 500
        timestamp
      end

    assert Enum.at(attempt_timestamps, 1) - Enum.at(attempt_timestamps, 0) >= 25
    assert Enum.at(attempt_timestamps, 2) - Enum.at(attempt_timestamps, 1) >= 55
    refute_received {:connect_attempted, _node, _timestamp}

    assert_receive {:leader_node_down, node}
    assert node == Node.self()

    assert_eventually(fn ->
      match?(
        %{"default" => %{"queued" => 0, "in_use" => 0, "available" => 1}},
        stringify_stats(LeaseManager.stats(manager))
      )
    end)

    assert %{"default" => %{"queued" => 0, "in_use" => 0, "available" => 1}} =
             stringify_stats(LeaseManager.stats(manager))

    assert_receive {:reconcile_node, node, opts}
    assert node == Node.self()
    assert opts[:reason] == "node reconnect failed after 3 attempts"
    assert opts[:redis_store] == RedisStoreStub
    assert opts[:event_bus] == EventBusStub

    send(monitor, {:nodeup, Node.self()})
    assert_receive {:node_state_marked, _node, "healthy", %{}}
    Process.sleep(25)
    refute_received {:job_persisted, _job_id, _updates, _defaults}
    refute_received {:event_published, "running-job", %{type: :job_resumed}}

    send(owner.pid, :release)
    assert :ok = Task.await(owner, 1_000)
  end

  defp start_monitor(opts) do
    start_supervised!(
      {NodeMonitor,
       Keyword.merge(
         [
           name: unique_name(),
           monitor_nodes: false,
           reconnect_attempts: 3,
           reconnect_backoff_ms: 1,
          node_state: NodeStateStub,
          leader: LeaderStub,
          reconciler: ReconcilerStub,
          redis_store: RedisStoreStub,
           event_bus: EventBusStub
         ],
         opts
       )}
    )
  end

  defp parent_pid, do: Process.whereis(@test_pid_name)

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    started_at = System.monotonic_time(:millisecond)
    do_assert_eventually(fun, started_at, timeout_ms)
  end

  defp do_assert_eventually(fun, started_at, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) - started_at > timeout_ms do
        flunk("condition was not met before timeout")
      else
        Process.sleep(10)
        do_assert_eventually(fun, started_at, timeout_ms)
      end
    end
  end

  defp stringify_stats(stats) do
    Enum.into(stats, %{}, fn {pool, values} -> {to_string(pool), stringify_map(values)} end)
  end

  defp stringify_map(values) when is_map(values) do
    Enum.into(values, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp unique_name do
    :"node-monitor-test-#{System.unique_integer([:positive])}"
  end
end
