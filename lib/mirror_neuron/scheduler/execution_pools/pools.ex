defmodule MirrorNeuron.Execution.LeaseManager.Pools do
  @moduledoc "Updates executor pool allocations and drains each independent waiting queue."

  alias MirrorNeuron.Execution.LeaseManager.Requests
  alias MirrorNeuron.Execution.LeaseManager.Timers

  def fetch_pool(state, pool) do
    case Map.fetch(state.pools, pool) do
      {:ok, pool_state} -> {:ok, pool_state}
      :error -> {:error, "unknown executor pool #{inspect(pool)}"}
    end
  end

  def validate_slots(capacity, slots)
      when is_integer(slots) and slots > 0 and slots <= capacity,
      do: :ok

  def validate_slots(capacity, slots) when is_integer(slots) and slots > capacity,
    do: {:error, "requested #{slots} executor slots but pool capacity is #{capacity}"}

  def validate_slots(_capacity, _slots),
    do: {:error, "executor slots must be a positive integer"}

  def capacity_available?(pool_state, slots),
    do: pool_state.in_use + slots <= pool_state.capacity

  def grant_request(request, state) do
    Timers.cancel_queue_timeout(request)

    monitor_ref =
      Map.get_lazy(request, :monitor_ref, fn ->
        Process.monitor(request.owner)
      end)

    acquired_at_ms = Requests.now_ms()

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

  def release_lease(state, lease_id) do
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

  def release_capacity_for_node(state, node) do
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

  def release_capacity_for_dead_owners(state) do
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

  def remove_waiting(state, lease_id) do
    monitor_ref = Map.get(state.lease_monitors, lease_id)
    request = Map.get(state.waiting, lease_id)

    if monitor_ref do
      Process.demonitor(monitor_ref, [:flush])
    end

    Timers.cancel_queue_timeout(request)

    state =
      if request do
        update_in(state, [:pools, request.pool, :waiting], fn queue ->
          queue
          |> :queue.to_list()
          |> Enum.reject(&(&1 == lease_id))
          |> :queue.from_list()
        end)
      else
        state
      end

    state
    |> Map.put(:waiting, Map.delete(state.waiting, lease_id))
    |> Map.put(:lease_monitors, Map.delete(state.lease_monitors, lease_id))
    |> Map.put(
      :monitors,
      if(monitor_ref, do: Map.delete(state.monitors, monitor_ref), else: state.monitors)
    )
  end

  def grant_waiting(state) do
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

  def reply_for_lease(lease) do
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

  def waiting_for_pool(waiting, pool) do
    waiting
    |> Enum.filter(fn {_lease_id, request} -> request.pool == pool end)
    |> Enum.into(%{})
  end

  defp owner_node(%{owner: owner}) when is_pid(owner), do: owner |> node() |> Atom.to_string()

  defp owner_node(_owner), do: nil

  defp owner_alive?(%{owner: owner}) when is_pid(owner), do: Process.alive?(owner)

  defp owner_alive?(_owner), do: false
end
