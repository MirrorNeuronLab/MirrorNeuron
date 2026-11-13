defmodule MirrorNeuron.Execution.LeaseManager do
  use GenServer

  @moduledoc "Executor pool GenServer; owns lease calls, process monitors and queue timeout messages."

  alias MirrorNeuron.Execution.LeaseManager.Pools
  alias MirrorNeuron.Execution.LeaseManager.Requests
  alias MirrorNeuron.Execution.LeaseManager.Settings
  alias MirrorNeuron.Execution.LeaseManager.Timers

  @default_pool "default"
  @default_queue_timeout_ms 30_000
  @default_max_queue_length 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def acquire(server \\ __MODULE__, pool, slots, metadata \\ %{}, opts \\ []) do
    GenServer.call(
      server,
      {:acquire, Settings.normalize_pool(pool), slots, metadata, opts},
      :infinity
    )
  end

  def release(server \\ __MODULE__, lease_id) do
    GenServer.cast(server, {:release, lease_id})
  end

  def release_node_capacity(node) do
    release_node_capacity(__MODULE__, node)
  end

  def release_node_capacity(server, node) do
    GenServer.call(server, {:release_node_capacity, Settings.normalize_node(node)})
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
        %{@default_pool => Settings.parse_positive_integer("MN_EXECUTOR_MAX_CONCURRENCY", 4)},
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
      |> Settings.normalize_capacities()

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
          Settings.config_positive_integer(
            "MN_LEASE_QUEUE_TIMEOUT_MS",
            :lease_queue_timeout_ms,
            @default_queue_timeout_ms
          ),
      max_queue_length:
        Keyword.get(opts, :max_queue_length) ||
          Settings.config_nonnegative_integer(
            "MN_LEASE_MAX_QUEUE_LENGTH",
            :lease_max_queue_length,
            @default_max_queue_length
          )
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, pool, slots, metadata, opts}, from, state) do
    with {:ok, pool_state} <- Pools.fetch_pool(state, pool),
         :ok <- Pools.validate_slots(pool_state.capacity, slots) do
      queue_timeout_ms = Settings.queue_timeout_ms(state, opts)
      max_queue_length = Settings.max_queue_length(state, opts)

      request = %{
        lease_id: Requests.lease_id(),
        pool: pool,
        slots: slots,
        metadata: Requests.stringify_map(metadata),
        requested_at_ms: Requests.now_ms(),
        owner: elem(from, 0),
        from: from,
        queue_timeout_ms: queue_timeout_ms
      }

      cond do
        Pools.capacity_available?(pool_state, slots) ->
          next_state = Pools.grant_request(request, state)
          {:reply, {:ok, Pools.reply_for_lease(next_state.leases[request.lease_id])}, next_state}

        Requests.queue_full?(pool_state, max_queue_length) ->
          {:reply,
           {:error,
            {:retry_later, Requests.queue_full_reason(pool, slots, pool_state, max_queue_length)}},
           state}

        true ->
          monitor_ref = Process.monitor(request.owner)
          timeout_ref = Timers.schedule_queue_timeout(request.lease_id, queue_timeout_ms)

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
           queued: map_size(Pools.waiting_for_pool(state.waiting, pool)),
           active: active
         }}
      end)
      |> Enum.into(%{})

    {:reply, stats, state}
  end

  def handle_call({:release_node_capacity, node}, _from, state) do
    next_state =
      state
      |> Pools.release_capacity_for_node(node)
      |> Pools.grant_waiting()

    {:reply, :ok, next_state}
  end

  def handle_call(:restore_capacity, _from, state) do
    next_state =
      state
      |> Pools.release_capacity_for_dead_owners()
      |> Pools.grant_waiting()

    {:reply, :ok, next_state}
  end

  @impl true
  def handle_cast({:release, lease_id}, state) do
    {:noreply, state |> Pools.release_lease(lease_id) |> Pools.grant_waiting()}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {{:waiting, lease_id}, remaining_monitors} ->
        next_state =
          %{state | monitors: remaining_monitors}
          |> Pools.remove_waiting(lease_id)
          |> Pools.grant_waiting()

        {:noreply, next_state}

      {{:active, lease_id}, remaining_monitors} ->
        next_state =
          %{state | monitors: remaining_monitors}
          |> Pools.release_lease(lease_id)
          |> Pools.grant_waiting()

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
        reason = Requests.queue_timeout_reason(request)
        GenServer.reply(request.from, {:error, {:retry_later, reason}})

        next_state =
          state
          |> Pools.remove_waiting(lease_id)
          |> Pools.grant_waiting()

        {:noreply, next_state}
    end
  end
end
