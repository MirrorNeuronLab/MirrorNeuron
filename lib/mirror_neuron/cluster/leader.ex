defmodule MirrorNeuron.Cluster.Leader do
  use GenServer
  require Logger

  alias MirrorNeuron.Cluster.{NodeDrainer, Reconciler}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.ScheduleDispatcher

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
      campaign_ref: nil,
      campaign_token: nil,
      sweep_ref: nil,
      sweep_token: nil,
      node_sweep_timers: %{}
    }

    state =
      if MirrorNeuron.Grpc.NetworkOnly.enabled?(), do: state, else: schedule_campaign(state, 500)

    {:ok, state}
  end

  @impl true
  def handle_info({:campaign, token}, %{campaign_token: token} = state) do
    state = clear_campaign_timer(state)

    if MirrorNeuron.Grpc.NetworkOnly.enabled?() do
      {:noreply, state}
    else
      {:noreply, state |> run_campaign() |> schedule_campaign(@refresh_interval_ms)}
    end
  end

  def handle_info({:campaign, _stale_token}, state), do: {:noreply, state}

  def handle_info(:campaign, state) do
    if MirrorNeuron.Grpc.NetworkOnly.enabled?() do
      {:noreply, state}
    else
      {:noreply, run_campaign(state)}
    end
  end

  def handle_info({:sweep_orphaned_jobs, token}, %{sweep_token: token} = state) do
    state = clear_sweep_timer(state)

    if state.is_leader do
      _ = sweep_orphaned_jobs()
      {:noreply, schedule_sweep(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:sweep_orphaned_jobs, stale_token}, state) when is_reference(stale_token),
    do: {:noreply, state}

  def handle_info(:sweep_orphaned_jobs, %{is_leader: true} = state) do
    _ = sweep_orphaned_jobs()
    {:noreply, state}
  end

  def handle_info(:sweep_orphaned_jobs, state), do: {:noreply, state}

  def handle_info(
        {:sweep_orphaned_jobs, node_name, token},
        %{node_sweep_timers: timers} = state
      ) do
    case Map.get(timers, node_name) do
      {_ref, ^token} ->
        state = clear_node_sweep_timer(state, node_name)
        if state.is_leader, do: sweep_orphaned_jobs(node_name)
        {:noreply, state}

      _stale_or_missing ->
        {:noreply, state}
    end
  end

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
    state = if state.is_leader, do: schedule_node_sweep(state, node_name), else: state
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = state |> cancel_campaign() |> cancel_sweep() |> cancel_node_sweeps()

    if state.is_leader do
      _ = RedisStore.release_lease("cluster:leader", state.node_name)
    end

    :ok
  end

  defp run_campaign(state) do
    current_node = to_string(Node.self())

    # If the node name changed (e.g. CLI fully initialized)
    state =
      if current_node != state.node_name do
        if state.is_leader do
          RedisStore.release_lease("cluster:leader", state.node_name)
        end

        state
        |> handle_lost_leadership()
        |> Map.put(:node_name, current_node)
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

    new_state
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

    state
    |> cancel_sweep()
    |> cancel_node_sweeps()
    |> Map.put(:is_leader, false)
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

    drain_result =
      case NodeDrainer.process_due_drains() do
        {:ok, result} ->
          %{
            checked: Map.get(result, "checked", 0),
            recovered: Map.get(result, "completed", 0),
            failed: Map.get(result, "failed", 0),
            paused: 0,
            blocked: Map.get(result, "blocked", 0),
            skipped: Map.get(result, "waiting", 0)
          }

        {:error, _reason} ->
          %{checked: 0, recovered: 0, failed: 0, paused: 0, blocked: 0, skipped: 0}
      end

    schedule_result =
      case ScheduleDispatcher.process_due_schedules() do
        {:ok, result} ->
          %{
            checked: Map.get(result, :checked, 0),
            recovered: Map.get(result, :dispatched, 0),
            failed: Map.get(result, :failed, 0),
            paused: 0,
            blocked: Map.get(result, :blocked, 0),
            skipped: Map.get(result, :skipped, 0) + Map.get(result, :missed, 0)
          }

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

    due_result
    |> Map.merge(drain_result, fn _key, left, right -> left + right end)
    |> Map.merge(schedule_result, fn _key, left, right -> left + right end)
    |> Map.merge(sweep_result, fn _key, left, right -> left + right end)
  end

  defp schedule_sweep(state) do
    state = cancel_sweep(state)
    token = make_ref()
    ref = Process.send_after(self(), {:sweep_orphaned_jobs, token}, @sweep_interval_ms)
    %{state | sweep_ref: ref, sweep_token: token}
  end

  defp cancel_sweep(%{sweep_ref: ref, sweep_token: token} = state) when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:sweep_orphaned_jobs, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_sweep_timer(state)
  end

  defp cancel_sweep(state), do: state

  defp clear_sweep_timer(state), do: %{state | sweep_ref: nil, sweep_token: nil}

  defp schedule_campaign(state, delay_ms) do
    state = cancel_campaign(state)
    token = make_ref()
    ref = Process.send_after(self(), {:campaign, token}, max(delay_ms, 0))
    %{state | campaign_ref: ref, campaign_token: token}
  end

  defp cancel_campaign(%{campaign_ref: ref, campaign_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:campaign, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_campaign_timer(state)
  end

  defp cancel_campaign(state), do: state

  defp clear_campaign_timer(state),
    do: %{state | campaign_ref: nil, campaign_token: nil}

  defp schedule_node_sweep(state, node_name) do
    state = cancel_node_sweep(state, node_name)
    token = make_ref()

    ref =
      Process.send_after(
        self(),
        {:sweep_orphaned_jobs, node_name, token},
        @node_down_sweep_delay_ms
      )

    put_in(state, [:node_sweep_timers, node_name], {ref, token})
  end

  defp cancel_node_sweep(%{node_sweep_timers: timers} = state, node_name) do
    case Map.get(timers, node_name) do
      {ref, token} ->
        Process.cancel_timer(ref)

        receive do
          {:sweep_orphaned_jobs, ^node_name, ^token} -> :ok
        after
          0 -> :ok
        end

        clear_node_sweep_timer(state, node_name)

      nil ->
        state
    end
  end

  defp clear_node_sweep_timer(state, node_name) do
    update_in(state.node_sweep_timers, &Map.delete(&1, node_name))
  end

  defp cancel_node_sweeps(%{node_sweep_timers: timers} = state) do
    Enum.reduce(Map.keys(timers), state, &cancel_node_sweep(&2, &1))
  end
end
