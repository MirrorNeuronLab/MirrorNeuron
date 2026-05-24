defmodule MirrorNeuron.Cluster.Leader do
  use GenServer
  require Logger

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.Persistence.RedisStore

  @lease_duration_ms 10_000
  @refresh_interval_ms 3_000
  @sweep_interval_ms 5_000
  @node_down_sweep_delay_ms 11_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep_now, 15_000)
  end

  def node_down(node, server \\ __MODULE__) do
    GenServer.cast(server, {:node_down, to_string(node)})
  end

  @impl true
  def init(:ok) do
    state = %{
      is_leader: false,
      node_name: to_string(Node.self()),
      sweep_ref: nil
    }

    Process.send_after(self(), :campaign, 500)
    {:ok, state}
  end

  @impl true
  def handle_info(:campaign, state) do
    current_node = to_string(Node.self())

    # If the node name changed (e.g. CLI fully initialized)
    state =
      if current_node != state.node_name do
        if state.is_leader do
          RedisStore.release_lease("cluster:leader", state.node_name)
        end

        %{state | is_leader: false, node_name: current_node}
      else
        state
      end

    new_state =
      if state.is_leader do
        case RedisStore.renew_lease("cluster:leader", state.node_name, @lease_duration_ms) do
          :ok ->
            # Keep leadership
            state

          {:error, _} ->
            # Failed to renew (e.g. expired and someone else took it)
            handle_lost_leadership(state)
        end
      else
        case RedisStore.acquire_lease("cluster:leader", state.node_name, @lease_duration_ms) do
          :ok ->
            handle_became_leader(state)

          {:error, :locked} ->
            state

          {:error, reason} ->
            Logger.warning("Redis error during leader campaign: #{inspect(reason)}")
            state
        end
      end

    Process.send_after(self(), :campaign, @refresh_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(:sweep_orphaned_jobs, %{is_leader: true} = state) do
    _ = sweep_orphaned_jobs()
    {:noreply, schedule_sweep(state)}
  end

  def handle_info(:sweep_orphaned_jobs, state), do: {:noreply, %{state | sweep_ref: nil}}

  def handle_info({:sweep_orphaned_jobs, node_name}, %{is_leader: true} = state) do
    _ = sweep_orphaned_jobs(node_name)
    {:noreply, state}
  end

  def handle_info({:sweep_orphaned_jobs, _node_name}, state), do: {:noreply, state}

  @impl true
  def handle_call(:sweep_now, _from, state) do
    result =
      if state.is_leader,
        do: sweep_orphaned_jobs(),
        else: %{checked: 0, recovered: 0, failed: 0, blocked: 0}

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_cast({:node_down, node_name}, state) do
    if state.is_leader do
      Process.send_after(self(), {:sweep_orphaned_jobs, node_name}, @node_down_sweep_delay_ms)
    end

    {:noreply, state}
  end

  defp handle_became_leader(state) do
    if not state.is_leader do
      Logger.notice("Node #{state.node_name} became cluster leader")
    end

    _ = sweep_orphaned_jobs()
    state |> Map.put(:is_leader, true) |> schedule_sweep()
  end

  defp handle_lost_leadership(state) do
    if state.is_leader do
      Logger.notice("Node #{state.node_name} lost cluster leadership")
    end

    cancel_sweep(state)
    %{state | is_leader: false, sweep_ref: nil}
  end

  defp sweep_orphaned_jobs(owner_node \\ nil) do
    reason =
      if owner_node,
        do: "node #{owner_node} lost its job lease",
        else: "lost job lease"

    due_result =
      case Reconciler.process_due_evals() do
        {:ok, result} ->
          Map.take(result, [:checked, :recovered, :failed, :paused, :blocked, :skipped])

        {:error, _reason} ->
          %{checked: 0, recovered: 0, failed: 0, paused: 0, blocked: 0, skipped: 0}
      end

    sweep_result =
      case Reconciler.sweep_orphaned_jobs(owner_node, reason: reason) do
        {:ok, result} ->
          Map.take(result, [:checked, :recovered, :failed, :paused, :blocked, :skipped])

        {:error, _reason} ->
          %{checked: 0, recovered: 0, failed: 0, paused: 0, blocked: 0, skipped: 0}
      end

    Map.merge(due_result, sweep_result, fn _key, left, right -> left + right end)
  end

  defp schedule_sweep(state) do
    cancel_sweep(state)
    %{state | sweep_ref: Process.send_after(self(), :sweep_orphaned_jobs, @sweep_interval_ms)}
  end

  defp cancel_sweep(%{sweep_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_sweep(_state), do: :ok
end
