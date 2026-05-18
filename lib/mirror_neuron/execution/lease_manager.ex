defmodule MirrorNeuron.Execution.LeaseManager do
  use GenServer

  @default_pool "default"
  @default_queue_timeout_ms 30_000
  @default_max_queue_length 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def acquire(server \\ __MODULE__, pool, slots, metadata \\ %{}, opts \\ []) do
    GenServer.call(server, {:acquire, normalize_pool(pool), slots, metadata, opts}, :infinity)
  end

  def release(server \\ __MODULE__, lease_id) do
    GenServer.cast(server, {:release, lease_id})
  end

  def release_node_capacity(node) do
    release_node_capacity(__MODULE__, node)
  end

  def release_node_capacity(server, node) do
    GenServer.call(server, {:release_node_capacity, normalize_node(node)})
  end

  def restore_capacity(server \\ __MODULE__) do
    GenServer.call(server, :restore_capacity)
  end

  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    default_capacities =
      "MN_EXECUTOR_POOL_CAPACITIES"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.reduce(
        %{@default_pool => parse_positive_integer("MN_EXECUTOR_MAX_CONCURRENCY", 4)},
        fn entry, acc ->
          case String.split(entry, "=", parts: 2) do
            [pool, raw_capacity] ->
              case Integer.parse(raw_capacity) do
                {capacity, ""} when capacity > 0 -> Map.put(acc, pool, capacity)
                _ -> acc
              end

            _ ->
              acc
          end
        end
      )

    capacities =
      opts
      |> Keyword.get(:capacities, default_capacities)
      |> normalize_capacities()

    state = %{
      pools:
        Enum.into(capacities, %{}, fn {pool, capacity} ->
          {pool, %{capacity: capacity, in_use: 0, waiting: :queue.new()}}
        end),
      leases: %{},
      waiting: %{},
      monitors: %{},
      lease_monitors: %{},
      queue_timeout_ms:
        Keyword.get(opts, :queue_timeout_ms) ||
          config_positive_integer(
            "MN_LEASE_QUEUE_TIMEOUT_MS",
            :lease_queue_timeout_ms,
            @default_queue_timeout_ms
          ),
      max_queue_length:
        Keyword.get(opts, :max_queue_length) ||
          config_nonnegative_integer(
            "MN_LEASE_MAX_QUEUE_LENGTH",
            :lease_max_queue_length,
            @default_max_queue_length
          )
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, pool, slots, metadata, opts}, from, state) do
    with {:ok, pool_state} <- fetch_pool(state, pool),
         :ok <- validate_slots(pool_state.capacity, slots) do
      queue_timeout_ms = queue_timeout_ms(state, opts)
      max_queue_length = max_queue_length(state, opts)

      request = %{
        lease_id: lease_id(),
        pool: pool,
        slots: slots,
        metadata: stringify_map(metadata),
        requested_at_ms: now_ms(),
        owner: elem(from, 0),
        from: from,
        queue_timeout_ms: queue_timeout_ms
      }

      cond do
        capacity_available?(pool_state, slots) ->
          next_state = grant_request(request, state)
          {:reply, {:ok, reply_for_lease(next_state.leases[request.lease_id])}, next_state}

        queue_full?(pool_state, max_queue_length) ->
          {:reply,
           {:error, {:retry_later, queue_full_reason(pool, slots, pool_state, max_queue_length)}},
           state}

        true ->
          monitor_ref = Process.monitor(request.owner)
          timeout_ref = schedule_queue_timeout(request.lease_id, queue_timeout_ms)

          next_state =
            state
            |> put_in([:pools, pool, :waiting], :queue.in(request.lease_id, pool_state.waiting))
            |> put_in(
              [:waiting, request.lease_id],
              request
              |> Map.put(:monitor_ref, monitor_ref)
              |> Map.put(:timeout_ref, timeout_ref)
            )
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

  def handle_call({:release_node_capacity, node}, _from, state) do
    next_state =
      state
      |> release_capacity_for_node(node)
      |> grant_waiting()

    {:reply, :ok, next_state}
  end

  def handle_call(:restore_capacity, _from, state) do
    next_state =
      state
      |> release_capacity_for_dead_owners()
      |> grant_waiting()

    {:reply, :ok, next_state}
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

  def handle_info({:queue_timeout, lease_id}, state) do
    case Map.get(state.waiting, lease_id) do
      nil ->
        {:noreply, state}

      request ->
        reason = queue_timeout_reason(request)
        GenServer.reply(request.from, {:error, {:retry_later, reason}})

        next_state =
          state
          |> remove_waiting(lease_id)
          |> grant_waiting()

        {:noreply, next_state}
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
    cancel_queue_timeout(request)

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

  defp release_capacity_for_node(state, node) do
    lease_ids =
      state.leases
      |> Enum.filter(fn {_lease_id, lease} -> owner_node(lease) == node end)
      |> Enum.map(fn {lease_id, _lease} -> lease_id end)

    waiting_ids =
      state.waiting
      |> Enum.filter(fn {_lease_id, request} -> owner_node(request) == node end)
      |> Enum.map(fn {lease_id, _request} -> lease_id end)

    state =
      Enum.reduce(lease_ids, state, fn lease_id, acc ->
        release_lease(acc, lease_id)
      end)

    Enum.reduce(waiting_ids, state, fn lease_id, acc ->
      remove_waiting(acc, lease_id)
    end)
  end

  defp release_capacity_for_dead_owners(state) do
    lease_ids =
      state.leases
      |> Enum.reject(fn {_lease_id, lease} -> owner_alive?(lease) end)
      |> Enum.map(fn {lease_id, _lease} -> lease_id end)

    waiting_ids =
      state.waiting
      |> Enum.reject(fn {_lease_id, request} -> owner_alive?(request) end)
      |> Enum.map(fn {lease_id, _request} -> lease_id end)

    state =
      Enum.reduce(lease_ids, state, fn lease_id, acc ->
        release_lease(acc, lease_id)
      end)

    Enum.reduce(waiting_ids, state, fn lease_id, acc ->
      remove_waiting(acc, lease_id)
    end)
  end

  defp remove_waiting(state, lease_id) do
    monitor_ref = Map.get(state.lease_monitors, lease_id)
    request = Map.get(state.waiting, lease_id)

    if monitor_ref do
      Process.demonitor(monitor_ref, [:flush])
    end

    cancel_queue_timeout(request)

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

  defp normalize_node(node) when is_atom(node), do: Atom.to_string(node)
  defp normalize_node(node) when is_binary(node), do: node
  defp normalize_node(node), do: to_string(node)

  defp owner_node(%{owner: owner}) when is_pid(owner), do: owner |> node() |> Atom.to_string()
  defp owner_node(_owner), do: nil

  defp owner_alive?(%{owner: owner}) when is_pid(owner), do: Process.alive?(owner)
  defp owner_alive?(_owner), do: false

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

  defp queue_full?(_pool_state, max_queue_length) when max_queue_length <= 0, do: false

  defp queue_full?(pool_state, max_queue_length) do
    :queue.len(pool_state.waiting) >= max_queue_length
  end

  defp queue_timeout_ms(state, opts) do
    opts
    |> Keyword.get(:queue_timeout_ms, state.queue_timeout_ms)
    |> normalize_positive_integer(state.queue_timeout_ms)
  end

  defp max_queue_length(state, opts) do
    opts
    |> Keyword.get(:max_queue_length, state.max_queue_length)
    |> normalize_nonnegative_integer(state.max_queue_length)
  end

  defp schedule_queue_timeout(_lease_id, timeout_ms) when timeout_ms <= 0, do: nil

  defp schedule_queue_timeout(lease_id, timeout_ms) do
    Process.send_after(self(), {:queue_timeout, lease_id}, timeout_ms)
  end

  defp cancel_queue_timeout(nil), do: :ok

  defp cancel_queue_timeout(%{timeout_ref: timeout_ref, lease_id: lease_id})
       when is_reference(timeout_ref) do
    Process.cancel_timer(timeout_ref)

    receive do
      {:queue_timeout, ^lease_id} -> :ok
    after
      0 -> :ok
    end
  end

  defp cancel_queue_timeout(_request), do: :ok

  defp queue_full_reason(pool, slots, pool_state, max_queue_length) do
    %{
      "reason" => "executor_pool_queue_full",
      "pool" => pool,
      "slots" => slots,
      "queued" => :queue.len(pool_state.waiting),
      "max_queue_length" => max_queue_length,
      "retry_after_ms" => 250
    }
  end

  defp queue_timeout_reason(request) do
    %{
      "reason" => "executor_pool_queue_timeout",
      "pool" => request.pool,
      "slots" => request.slots,
      "queue_wait_ms" => max(now_ms() - request.requested_at_ms, 0),
      "timeout_ms" => request.queue_timeout_ms,
      "retry_after_ms" => 250
    }
  end

  defp lease_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp parse_positive_integer(env_name, default) do
    case System.get_env(env_name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> normalize_positive_integer(value, default)
    end
  end

  defp config_nonnegative_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> normalize_nonnegative_integer(value, default)
    end
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_nonnegative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_nonnegative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_nonnegative_integer(_value, default), do: default
end
