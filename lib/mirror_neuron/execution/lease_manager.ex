defmodule MirrorNeuron.Execution.LeaseManager do
  use GenServer

  @default_pool "default"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def acquire(server \\ __MODULE__, pool, slots, metadata \\ %{}) do
    GenServer.call(server, {:acquire, normalize_pool(pool), slots, metadata}, :infinity)
  end

  def release(server \\ __MODULE__, lease_id) do
    GenServer.cast(server, {:release, lease_id})
  end

  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    capacities =
      opts
      |> Keyword.get(
        :capacities,
        Application.get_env(:mirror_neuron, :executor_pool_capacities, %{@default_pool => 4})
      )
      |> normalize_capacities()

    state = %{
      pools:
        Enum.into(capacities, %{}, fn {pool, capacity} ->
          {pool, %{capacity: capacity, in_use: 0, waiting: :queue.new()}}
        end),
      leases: %{},
      waiting: %{},
      monitors: %{},
      lease_monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, pool, slots, metadata}, from, state) do
    with {:ok, pool_state} <- fetch_pool(state, pool),
         :ok <- validate_slots(pool_state.capacity, slots) do
      request = %{
        lease_id: lease_id(),
        pool: pool,
        slots: slots,
        metadata: stringify_map(metadata),
        requested_at_ms: now_ms(),
        owner: elem(from, 0),
        from: from
      }

      if capacity_available?(pool_state, slots) do
        next_state = grant_request(request, state)
        {:reply, {:ok, reply_for_lease(next_state.leases[request.lease_id])}, next_state}
      else
        monitor_ref = Process.monitor(request.owner)

        next_state =
          state
          |> put_in([:pools, pool, :waiting], :queue.in(request.lease_id, pool_state.waiting))
          |> put_in([:waiting, request.lease_id], Map.put(request, :monitor_ref, monitor_ref))
          |> put_in([:monitors, monitor_ref], {:waiting, request.lease_id})
          |> put_in([:lease_monitors, request.lease_id], monitor_ref)

        {:noreply, next_state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      state.pools
      |> Enum.map(fn {pool, pool_state} ->
        active =
          Enum.count(state.leases, fn {_lease_id, lease} ->
            lease.pool == pool
          end)

        {pool,
         %{
           capacity: pool_state.capacity,
           in_use: pool_state.in_use,
           available: max(pool_state.capacity - pool_state.in_use, 0),
           queued: map_size(waiting_for_pool(state.waiting, pool)),
           active: active
         }}
      end)
      |> Enum.into(%{})

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:release, lease_id}, state) do
    {:noreply, state |> release_lease(lease_id) |> grant_waiting()}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {{:waiting, lease_id}, remaining_monitors} ->
        next_state =
          %{state | monitors: remaining_monitors}
          |> remove_waiting(lease_id)
          |> grant_waiting()

        {:noreply, next_state}

      {{:active, lease_id}, remaining_monitors} ->
        next_state =
          %{state | monitors: remaining_monitors}
          |> release_lease(lease_id)
          |> grant_waiting()

        {:noreply, next_state}

      {nil, _interim} ->
        {:noreply, state}
    end
  end

  defp fetch_pool(state, pool) do
    case Map.fetch(state.pools, pool) do
      {:ok, pool_state} -> {:ok, pool_state}
      :error -> {:error, "unknown executor pool #{inspect(pool)}"}
    end
  end

  defp validate_slots(capacity, slots)
       when is_integer(slots) and slots > 0 and slots <= capacity,
       do: :ok

  defp validate_slots(capacity, slots) when is_integer(slots) and slots > capacity,
    do: {:error, "requested #{slots} executor slots but pool capacity is #{capacity}"}

  defp validate_slots(_capacity, _slots),
    do: {:error, "executor slots must be a positive integer"}

  defp capacity_available?(pool_state, slots),
    do: pool_state.in_use + slots <= pool_state.capacity

  defp grant_request(request, state) do
    monitor_ref =
      Map.get_lazy(request, :monitor_ref, fn ->
        Process.monitor(request.owner)
      end)

    acquired_at_ms = now_ms()

    lease = %{
      lease_id: request.lease_id,
      pool: request.pool,
      slots: request.slots,
      metadata: request.metadata,
      owner: request.owner,
      requested_at_ms: request.requested_at_ms,
      acquired_at_ms: acquired_at_ms,
      queue_wait_ms: max(acquired_at_ms - request.requested_at_ms, 0)
    }

    state
    |> update_in([:pools, request.pool, :in_use], &(&1 + request.slots))
    |> put_in([:leases, request.lease_id], lease)
    |> Map.update!(:waiting, &Map.delete(&1, request.lease_id))
    |> Map.put(:lease_monitors, Map.put(state.lease_monitors, request.lease_id, monitor_ref))
    |> Map.put(:monitors, Map.put(state.monitors, monitor_ref, {:active, request.lease_id}))
  end

  defp release_lease(state, lease_id) do
    case Map.pop(state.leases, lease_id) do
      {nil, remaining_leases} ->
        %{state | leases: remaining_leases}
        |> remove_waiting(lease_id)

      {lease, remaining_leases} ->
        monitor_ref = Map.get(state.lease_monitors, lease_id)

        if monitor_ref do
          Process.demonitor(monitor_ref, [:flush])
        end

        %{state | leases: remaining_leases}
        |> update_in([:pools, lease.pool, :in_use], &max(&1 - lease.slots, 0))
        |> Map.put(:lease_monitors, Map.delete(state.lease_monitors, lease_id))
        |> Map.put(
          :monitors,
          if(monitor_ref, do: Map.delete(state.monitors, monitor_ref), else: state.monitors)
        )
        |> remove_waiting(lease_id)
    end
  end

  defp remove_waiting(state, lease_id) do
    monitor_ref = Map.get(state.lease_monitors, lease_id)

    if monitor_ref do
      Process.demonitor(monitor_ref, [:flush])
    end

    state
    |> Map.put(:waiting, Map.delete(state.waiting, lease_id))
    |> Map.put(:lease_monitors, Map.delete(state.lease_monitors, lease_id))
    |> Map.put(
      :monitors,
      if(monitor_ref, do: Map.delete(state.monitors, monitor_ref), else: state.monitors)
    )
  end

  defp grant_waiting(state) do
    Enum.reduce(Map.keys(state.pools), state, &drain_pool_queue/2)
  end

  defp drain_pool_queue(pool, state) do
    case get_in(state, [:pools, pool, :waiting]) |> :queue.out() do
      {{:value, lease_id}, remaining_queue} ->
        state = put_in(state, [:pools, pool, :waiting], remaining_queue)

        case Map.get(state.waiting, lease_id) do
          nil ->
            drain_pool_queue(pool, state)

          request ->
            pool_state = state.pools[pool]

            if capacity_available?(pool_state, request.slots) do
              next_state = grant_request(request, state)
              lease = next_state.leases[lease_id]
              GenServer.reply(request.from, {:ok, reply_for_lease(lease)})
              drain_pool_queue(pool, next_state)
            else
              put_in(state, [:pools, pool, :waiting], :queue.in_r(lease_id, remaining_queue))
            end
        end

      {:empty, _queue} ->
        state
    end
  end

  defp reply_for_lease(lease) do
    %{
      "lease_id" => lease.lease_id,
      "pool" => lease.pool,
      "slots" => lease.slots,
      "queue_wait_ms" => lease.queue_wait_ms,
      "requested_at_ms" => lease.requested_at_ms,
      "acquired_at_ms" => lease.acquired_at_ms,
      "metadata" => lease.metadata
    }
  end

  defp waiting_for_pool(waiting, pool) do
    waiting
    |> Enum.filter(fn {_lease_id, request} -> request.pool == pool end)
    |> Enum.into(%{})
  end

  defp normalize_capacities(capacities) when is_map(capacities) do
    capacities
    |> Enum.map(fn {pool, capacity} ->
      {normalize_pool(pool), normalize_capacity(capacity)}
    end)
    |> Enum.reject(fn {_pool, capacity} -> is_nil(capacity) end)
    |> Enum.into(%{})
    |> case do
      %{} = empty when map_size(empty) == 0 -> %{@default_pool => 4}
      pools -> pools
    end
  end

  defp normalize_capacity(capacity) when is_integer(capacity) and capacity > 0, do: capacity
  defp normalize_capacity(_capacity), do: nil

  defp normalize_pool(pool) when is_atom(pool), do: Atom.to_string(pool)
  defp normalize_pool(pool) when is_binary(pool) and pool != "", do: pool
  defp normalize_pool(_pool), do: @default_pool

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
      {normalized_key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp lease_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
