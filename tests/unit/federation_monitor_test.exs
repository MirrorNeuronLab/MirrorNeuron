defmodule MirrorNeuron.Cluster.FederationMonitorTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.FederationMonitor

  defmodule RegistryStub do
    def list, do: [%{"node_name" => "mirror_neuron@peer"}]

    def mark_available(name) do
      send(:persistent_term.get({__MODULE__, :test}), {:marked_available, name})
      :ok
    end

    def mark_unavailable(name) do
      send(:persistent_term.get({__MODULE__, :test}), {:marked_unavailable, name})
      :ok
    end

    def mark_projections_stale(name) do
      send(:persistent_term.get({__MODULE__, :test}), {:projections_stale, name})
      :ok
    end
  end

  setup do
    :persistent_term.put({RegistryStub, :test}, self())
    supervisor = start_supervised!({Task.Supervisor, name: FederationMonitorTestTasks})

    on_exit(fn -> :persistent_term.erase({RegistryStub, :test}) end)

    {:ok, supervisor: supervisor}
  end

  test "three failed probes mark unavailable and the next success restores health", %{
    supervisor: supervisor
  } do
    test_pid = self()
    outcomes = start_supervised!({Agent, fn -> [:timeout, :timeout, :timeout, :ok] end})

    probe = fn _name ->
      result = Agent.get_and_update(outcomes, fn [head | tail] -> {head, tail} end)
      send(test_pid, {:probe_result, result})
      if result == :ok, do: :ok, else: {:error, result}
    end

    monitor = start_monitor(supervisor, probe, fn _ -> {:ok, %{}} end)

    for attempt <- 1..3 do
      send(monitor, :sync)
      assert_receive {:probe_result, :timeout}
      await_failures(monitor, attempt)

      if attempt < 3 do
        refute_received {:marked_unavailable, _}
      end
    end

    assert_receive {:marked_unavailable, "mirror_neuron@peer"}
    send(monitor, :sync)
    assert_receive {:probe_result, :ok}
    assert_receive {:marked_available, "mirror_neuron@peer"}
    await_failures(monitor, 0)
  end

  test "sync failure stales projections without changing availability", %{supervisor: supervisor} do
    test_pid = self()

    probe = fn _ ->
      send(test_pid, :probe_succeeded)
      :ok
    end

    monitor = start_monitor(supervisor, probe, fn _ -> {:error, :sync_timeout} end)

    send(monitor, :sync)
    assert_receive :probe_succeeded
    assert_receive {:projections_stale, "mirror_neuron@peer"}
    refute_received {:marked_unavailable, _}
    await_sync_failures(monitor, 1)

    send(monitor, :sync)
    assert_receive :probe_succeeded
    refute_received {:projections_stale, _}
    await_sync_failures(monitor, 1)
  end

  test "slow sync does not block probes or start another sync", %{supervisor: supervisor} do
    test_pid = self()

    sync = fn _ ->
      send(test_pid, {:sync_started, self()})

      receive do
        :release_sync -> {:ok, %{}}
      end
    end

    probe = fn _ ->
      send(test_pid, :probe_succeeded)
      :ok
    end

    monitor = start_monitor(supervisor, probe, sync)

    send(monitor, :sync)
    assert_receive :probe_succeeded
    assert_receive {:sync_started, worker}

    send(monitor, :sync)
    assert_receive :probe_succeeded
    refute_received {:sync_started, _}

    send(worker, :release_sync)
    await_sync_failures(monitor, 0)
  end

  defp start_monitor(supervisor, probe, sync) do
    start_supervised!(
      {FederationMonitor,
       name: FederationMonitorTestServer,
       task_supervisor: supervisor,
       registry: RegistryStub,
       probe: probe,
       sync: sync,
       refresh: fn -> :ok end,
       initial_delay_ms: 60_000,
       interval_ms: 60_000}
    )
  end

  defp await_failures(monitor, expected) do
    assert_eventually(fn ->
      get_in(:sys.get_state(monitor), [:peers, "mirror_neuron@peer", :failures]) == expected
    end)
  end

  defp await_sync_failures(monitor, expected) do
    assert_eventually(fn ->
      get_in(:sys.get_state(monitor), [:peers, "mirror_neuron@peer", :sync_failures]) == expected
    end)
  end

  defp assert_eventually(predicate, attempts \\ 50)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
