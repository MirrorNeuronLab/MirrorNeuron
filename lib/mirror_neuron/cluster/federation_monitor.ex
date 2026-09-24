defmodule MirrorNeuron.Cluster.FederationMonitor do
  @moduledoc false
  use GenServer
  require Logger

  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry}

  @interval 5_000
  @failed_probes_allowed 3

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def sync_now, do: GenServer.call(__MODULE__, :sync_now, 30_000)

  def request_failed(node_name, operation, reason) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:request_failed, node_name, operation, failure_status(reason)})
    end

    :ok
  end

  @impl true
  def init(opts) do
    schedule(Keyword.get(opts, :initial_delay_ms, 250))

    {:ok,
     %{
       peers: %{},
       tasks: %{},
       probe: Keyword.get(opts, :probe, &FederationClient.probe_peer/1),
       sync: Keyword.get(opts, :sync, &FederationClient.sync_peer/1),
       refresh: Keyword.get(opts, :refresh, &MirrorNeuron.Cluster.EndpointRefresh.refresh/0),
       interval_ms: Keyword.get(opts, :interval_ms, @interval),
       registry: Keyword.get(opts, :registry, FederationRegistry),
       task_supervisor:
         Keyword.get(opts, :task_supervisor, MirrorNeuron.Cluster.FederationTaskSupervisor)
     }}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    result =
      state.registry.list()
      |> Map.new(fn peer ->
        name = peer["node_name"]
        {name, state.sync.(name)}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:request_failed, name, operation, status}, state) do
    peer = Map.get(state.peers, name)
    failures = if peer, do: peer.failures, else: 0
    last_success = if peer, do: peer.last_success, else: nil

    Logger.warning(
      "federated peer request failed: node=#{name} operation=#{operation} " <>
        "status=#{status} failures=#{failures} last_success=#{format_success(last_success)}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:sync, state) do
    _ = state.refresh.()
    now = System.monotonic_time(:millisecond)
    names = Enum.map(state.registry.list(), & &1["node_name"])
    state = %{state | peers: Map.take(state.peers, names)}

    state =
      Enum.reduce(names, state, fn name, acc ->
        acc = start_task(acc, name, :probe)
        peer = Map.get(acc.peers, name, initial_peer(now))

        if peer.next_sync <= now do
          start_task(acc, name, :sync)
        else
          acc
        end
      end)

    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{tasks: tasks} = state) when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{name, kind}, remaining} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_task(%{state | tasks: remaining}, name, kind, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = state) do
    case Map.pop(tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{name, kind}, remaining} ->
        {:noreply, finish_task(%{state | tasks: remaining}, name, kind, {:error, reason})}
    end
  end

  # grpc-elixir's Gun transport sends channel teardown notifications to its caller.
  def handle_info({event, _connection, _protocol, _reason, _streams}, state)
      when event in [:gun_down, :gun_up],
      do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp start_task(state, name, kind) do
    if Enum.any?(state.tasks, fn {_ref, entry} -> entry == {name, kind} end) do
      state
    else
      work = if kind == :probe, do: state.probe, else: state.sync
      task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> work.(name) end)
      %{state | tasks: Map.put(state.tasks, task.ref, {name, kind})}
    end
  end

  defp finish_task(state, name, kind, result) do
    if Enum.any?(state.registry.list(), &(&1["node_name"] == name)) do
      now = System.monotonic_time(:millisecond)
      peer = Map.get(state.peers, name, initial_peer(now))

      case {kind, result} do
        {:probe, :ok} ->
          available =
            if peer.available == true do
              true
            else
              mark_result_ok?(state.registry.mark_available(name))
            end

          put_in(state.peers[name], %{
            peer
            | failures: 0,
              available: available,
              last_success: DateTime.utc_now()
          })

        {:probe, error} ->
          failures = peer.failures + 1
          log_failure(name, :get_federated_peer, error, failures, peer.last_success)

          available =
            if failures >= @failed_probes_allowed and peer.available != false do
              if mark_result_ok?(state.registry.mark_unavailable(name)),
                do: false,
                else: peer.available
            else
              peer.available
            end

          put_in(state.peers[name], %{peer | failures: failures, available: available})

        {:sync, {:ok, _}} ->
          put_in(state.peers[name], %{peer | sync_failures: 0, next_sync: now + @interval})

        {:sync, error} ->
          failures = min(peer.sync_failures + 1, 4)
          _ = state.registry.mark_projections_stale(name)
          log_failure(name, :sync_peer, error, failures, peer.last_success)

          put_in(state.peers[name], %{
            peer
            | sync_failures: failures,
              next_sync: now + retry_delay(failures)
          })
      end
    else
      state
    end
  end

  defp initial_peer(now) do
    %{failures: 0, sync_failures: 0, next_sync: now, last_success: nil, available: :unknown}
  end

  defp mark_result_ok?(:ok), do: true
  defp mark_result_ok?({:ok, _}), do: true
  defp mark_result_ok?({:ok, _, _}), do: true
  defp mark_result_ok?(_), do: false

  defp log_failure(name, operation, error, count, last_success) do
    reason =
      case error do
        {:error, value} -> value
        value -> value
      end

    Logger.warning(
      "federated peer check failed: node=#{name} operation=#{operation} " <>
        "status=#{failure_status(reason)} failures=#{count} " <>
        "last_success=#{format_success(last_success)}"
    )
  end

  defp failure_status(%GRPC.RPCError{status: status}), do: "grpc_#{status}"
  defp failure_status(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_status(_reason), do: "peer_call_failed"

  defp format_success(nil), do: "never"
  defp format_success(value), do: DateTime.to_iso8601(value)

  defp schedule(delay), do: Process.send_after(self(), :sync, delay)

  def retry_delay(failures), do: min(@interval * Integer.pow(2, min(max(failures, 0), 4)), 60_000)
end
