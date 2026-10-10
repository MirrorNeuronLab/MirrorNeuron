defmodule MirrorNeuron.Cluster.FederationChannels do
  @moduledoc false
  use GenServer

  @checkout_timeout 20_000
  @idle_ms 300_000
  @sweep_ms 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def checkout(key, connect, server \\ __MODULE__) do
    lease = make_ref()

    try do
      GenServer.call(server, {:checkout, key, connect, lease}, @checkout_timeout)
    catch
      :exit, reason ->
        release(lease, false, server)
        exit(reason)
    end
  end

  def release(lease, invalidate? \\ false, server \\ __MODULE__) do
    GenServer.cast(server, {:release, lease, invalidate?})
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :sweep, @sweep_ms)

    {:ok,
     %{
       entries: %{},
       leases: %{},
       monitors: %{},
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       disconnect: Keyword.get(opts, :disconnect, &GRPC.Stub.disconnect/1),
       max_entries: Keyword.get(opts, :max_entries, 64),
       max_leases: Keyword.get(opts, :max_leases, 1_024),
       idle_ms: Keyword.get(opts, :idle_ms, @idle_ms)
     }}
  end

  @impl true
  def handle_call({:checkout, key, connect, lease}, from, state) do
    state = retire_other_credentials(state, key)
    state = make_room(state, key)
    entry = Map.get(state.entries, key)

    cond do
      map_size(state.leases) >= state.max_leases ->
        {:reply, {:error, :federation_channel_capacity}, state}

      entry != nil and entry.retired ->
        {:reply, {:error, :federation_channel_draining}, state}

      entry != nil ->
        state = add_lease(state, key, lease, from)
        {:noreply, grant_if_ready(state, key, lease)}

      map_size(state.entries) >= state.max_entries ->
        {:reply, {:error, :federation_channel_capacity}, state}

      true ->
        parent = self()
        disconnect = state.disconnect

        {worker, monitor} =
          spawn_monitor(fn -> connection_owner(parent, key, connect, disconnect) end)

        entry = %{
          worker: worker,
          monitor: monitor,
          channel: nil,
          leases: MapSet.new(),
          retired: false,
          last_used: state.clock.()
        }

        {:noreply, state |> put_in([:entries, key], entry) |> add_lease(key, lease, from)}
    end
  end

  @impl true
  def handle_cast({:release, lease, invalidate?}, state) do
    {:noreply, return_lease(state, lease, invalidate?)}
  end

  @impl true
  def handle_info({:connected, key, worker, {:ok, channel}}, state) do
    case Map.get(state.entries, key) do
      %{worker: ^worker} = entry ->
        state = put_in(state.entries[key].channel, channel)

        state =
          Enum.reduce(entry.leases, state, fn lease, acc ->
            if entry.retired do
              reply_pending(acc, lease, {:error, :federation_channel_draining})
              return_lease(acc, lease, false)
            else
              grant_if_ready(acc, key, lease)
            end
          end)

        {:noreply, close_if_retired(state, key)}

      _ ->
        send(worker, :disconnect)
        {:noreply, state}
    end
  end

  def handle_info({:connected, key, worker, {:error, reason}}, state) do
    case Map.get(state.entries, key) do
      %{worker: ^worker} -> {:noreply, drop_entry(state, key, reason)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      nil ->
        case Enum.find(state.entries, fn {_key, entry} -> entry.monitor == monitor end) do
          {key, _entry} -> {:noreply, drop_entry(state, key, :federation_channel_closed)}
          nil -> {:noreply, state}
        end

      lease ->
        {:noreply, return_lease(state, lease, false)}
    end
  end

  def handle_info(:sweep, state) do
    now = state.clock.()

    state =
      Enum.reduce(state.entries, state, fn {key, entry}, acc ->
        if idle?(entry) and now - entry.last_used >= state.idle_ms,
          do: drop_entry(acc, key),
          else: acc
      end)

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.entries, fn {_key, entry} -> send(entry.worker, :disconnect) end)
  end

  # Channel headers contain credentials. OTP diagnostics must never render them.
  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, %{
      entries: map_size(status.state.entries),
      leases: map_size(status.state.leases)
    })
    |> Map.replace(:message, :redacted)
    |> Map.replace(:reason, :redacted)
    |> Map.replace(:log, [])
  end

  defp add_lease(state, key, lease, {caller, _tag} = from) do
    monitor = Process.monitor(caller)

    state
    |> put_in([:leases, lease], %{key: key, monitor: monitor, from: from})
    |> put_in([:monitors, monitor], lease)
    |> update_in([:entries, key, :leases], &MapSet.put(&1, lease))
  end

  defp grant_if_ready(state, key, lease) do
    case {state.entries[key].channel, state.leases[lease]} do
      {nil, _} ->
        state

      {channel, %{from: from}} when from != nil ->
        GenServer.reply(from, {:ok, lease, channel})
        put_in(state.leases[lease].from, nil)

      _ ->
        state
    end
  end

  defp reply_pending(state, lease, result) do
    case Map.get(state.leases, lease) do
      %{from: from} when from != nil -> GenServer.reply(from, result)
      _ -> :ok
    end
  end

  defp return_lease(state, lease, invalidate?) do
    case Map.pop(state.leases, lease) do
      {nil, _} ->
        state

      {%{key: key, monitor: monitor}, leases} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | leases: leases, monitors: Map.delete(state.monitors, monitor)}

        case Map.get(state.entries, key) do
          nil ->
            state

          entry ->
            state =
              put_in(state.entries[key], %{
                entry
                | leases: MapSet.delete(entry.leases, lease),
                  retired: entry.retired or invalidate?,
                  last_used: state.clock.()
              })

            close_if_retired(state, key)
        end
    end
  end

  defp retire_other_credentials(state, {peer, _, _, _} = key) do
    Enum.reduce(state.entries, state, fn
      {{^peer, _, _, _} = other, _entry}, acc when other != key ->
        acc |> put_in([:entries, other, :retired], true) |> close_if_retired(other)

      _, acc ->
        acc
    end)
  end

  defp close_if_retired(state, key) do
    case Map.get(state.entries, key) do
      %{retired: true} = entry ->
        if idle?(entry), do: drop_entry(state, key), else: state

      _ ->
        state
    end
  end

  defp make_room(state, key) do
    if not Map.has_key?(state.entries, key) and map_size(state.entries) >= state.max_entries do
      state.entries
      |> Enum.filter(fn {_key, entry} -> idle?(entry) end)
      |> Enum.min_by(fn {_key, entry} -> entry.last_used end, fn -> nil end)
      |> case do
        {oldest, _entry} -> drop_entry(state, oldest)
        nil -> state
      end
    else
      state
    end
  end

  defp idle?(entry), do: entry.channel != nil and MapSet.size(entry.leases) == 0

  defp drop_entry(state, key, reason \\ :federation_channel_closed) do
    case Map.pop(state.entries, key) do
      {nil, _} ->
        state

      {entry, entries} ->
        send(entry.worker, :disconnect)
        Process.demonitor(entry.monitor, [:flush])
        state = %{state | entries: entries}

        Enum.reduce(entry.leases, state, fn lease, acc ->
          reply_pending(acc, lease, {:error, reason})
          return_lease(acc, lease, false)
        end)
    end
  end

  defp connection_owner(parent, key, connect, disconnect) do
    parent_monitor = Process.monitor(parent)

    result =
      try do
        connect.()
      rescue
        _ -> {:error, :federation_channel_connect_failed}
      end

    send(parent, {:connected, key, self(), result})

    case result do
      {:ok, channel} -> hold_connection(parent_monitor, channel, disconnect)
      _ -> :ok
    end
  end

  defp hold_connection(parent_monitor, channel, disconnect) do
    receive do
      :disconnect -> disconnect.(channel)
      {:DOWN, ^parent_monitor, :process, _, _} -> disconnect.(channel)
      _ -> hold_connection(parent_monitor, channel, disconnect)
    end
  end
end
