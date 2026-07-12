defmodule MirrorNeuron.Persistence.CheckpointLock do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def with_lock(resource, operation) when is_function(operation, 0) do
    :ok = GenServer.call(__MODULE__, {:acquire, resource}, :infinity)

    try do
      operation.()
    after
      :ok = GenServer.call(__MODULE__, {:release, resource}, :infinity)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, resource}, from, state) do
    owner = elem(from, 0)

    case Map.get(state.locks, resource) do
      nil ->
        monitor = Process.monitor(owner)
        lock = %{owner: owner, monitor: monitor, waiters: :queue.new()}

        {:reply, :ok,
         %{
           state
           | locks: Map.put(state.locks, resource, lock),
             monitors: Map.put(state.monitors, monitor, resource)
         }}

      lock ->
        lock = %{lock | waiters: :queue.in({from, owner}, lock.waiters)}
        {:noreply, %{state | locks: Map.put(state.locks, resource, lock)}}
    end
  end

  def handle_call({:release, resource}, from, state) do
    owner = elem(from, 0)

    case Map.get(state.locks, resource) do
      %{owner: ^owner} = lock ->
        Process.demonitor(lock.monitor, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, lock.monitor)}
        {:reply, :ok, grant_next(resource, lock.waiters, state)}

      _lock ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {resource, monitors} ->
        lock = Map.fetch!(state.locks, resource)
        state = %{state | monitors: monitors}
        {:noreply, grant_next(resource, lock.waiters, state)}
    end
  end

  defp grant_next(resource, waiters, state) do
    case next_live_waiter(waiters) do
      {:ok, from, owner, remaining} ->
        monitor = Process.monitor(owner)
        lock = %{owner: owner, monitor: monitor, waiters: remaining}
        GenServer.reply(from, :ok)

        %{
          state
          | locks: Map.put(state.locks, resource, lock),
            monitors: Map.put(state.monitors, monitor, resource)
        }

      :empty ->
        %{state | locks: Map.delete(state.locks, resource)}
    end
  end

  defp next_live_waiter(waiters) do
    case :queue.out(waiters) do
      {{:value, {from, owner}}, remaining} ->
        if Process.alive?(owner) do
          {:ok, from, owner, remaining}
        else
          next_live_waiter(remaining)
        end

      {:empty, _waiters} ->
        :empty
    end
  end
end
