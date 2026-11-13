defmodule MirrorNeuron.Runtime.ReliabilityObserver do
  @moduledoc false

  use GenServer

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{EventBus, ReliabilityStrategy}

  @cluster_job_id "__cluster__"
  @default_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, interval_ms()),
      snapshot: Keyword.get(opts, :snapshot, &ReliabilityStrategy.cluster_snapshot/0),
      redis_store: Keyword.get(opts, :redis_store, RedisStore),
      event_bus: Keyword.get(opts, :event_bus, EventBus),
      last_mode: nil,
      job_statuses: %{},
      tick_timer_ref: nil,
      tick_token: nil
    }

    state =
      if Keyword.get(opts, :schedule_initial_tick, true), do: schedule_tick(state, 0), else: state

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, token}, %{tick_token: token} = state) do
    state = clear_tick_timer(state)
    {:noreply, state |> run_tick() |> schedule_tick(state.interval_ms)}
  end

  def handle_info({:tick, _stale_token}, state), do: {:noreply, state}

  def handle_info(:tick, state), do: {:noreply, run_tick(state)}

  @impl true
  def terminate(_reason, state) do
    cancel_tick_timer(state)
    :ok
  end

  defp run_tick(state) do
    snapshot = state.snapshot.()
    state = maybe_publish_mode_change(snapshot, state)
    maybe_publish_job_changes(snapshot, state)
  end

  defp maybe_publish_mode_change(snapshot, %{last_mode: mode} = state)
       when mode == snapshot.mode do
    state
  end

  defp maybe_publish_mode_change(snapshot, state) do
    state.event_bus.publish(@cluster_job_id, %{
      type: :cluster_reliability_mode_changed,
      mode: snapshot.mode,
      observed_nodes: snapshot.observed_nodes,
      timestamp: Runtime.timestamp()
    })

    %{state | last_mode: snapshot.mode}
  end

  defp maybe_publish_job_changes(snapshot, state) do
    case list_job_summaries(state.redis_store) do
      {:ok, jobs} ->
        active_jobs = Enum.filter(jobs, &active_job?/1)
        active_job_ids = Enum.map(active_jobs, & &1["job_id"])
        state = %{state | job_statuses: Map.take(state.job_statuses, active_job_ids)}

        Enum.reduce(active_jobs, state, fn job, acc ->
          maybe_publish_job_change(job, snapshot, acc)
        end)

      {:error, _reason} ->
        state
    end
  end

  defp list_job_summaries(store) do
    if function_exported?(store, :list_job_summaries, 0) do
      store.list_job_summaries()
    else
      store.list_jobs()
    end
  end

  defp maybe_publish_job_change(job, snapshot, state) do
    job_id = job["job_id"]
    next = job_reliability_status(job, snapshot)
    previous = Map.get(state.job_statuses, job_id)

    maybe_publish_job_status(job, previous, next, snapshot, state)

    put_in(state.job_statuses[job_id], next)
  end

  defp maybe_publish_job_status(job, :degraded, :ok, snapshot, state) do
    publish_job_status(job, :restored, snapshot, state)
  end

  defp maybe_publish_job_status(job, previous, next, snapshot, state)
       when next in [:degraded, :restored] and next != previous do
    publish_job_status(job, next, snapshot, state)
  end

  defp maybe_publish_job_status(_job, _previous, _next, _snapshot, _state), do: :ok

  defp job_reliability_status(%{"reliability" => %{"degraded" => true}} = job, snapshot) do
    if ReliabilityStrategy.cluster_recoverable_now?(job, snapshot), do: :restored, else: :degraded
  end

  defp job_reliability_status(%{"recovery_policy" => "cluster_recover"} = job, snapshot) do
    if ReliabilityStrategy.cluster_recoverable_now?(job, snapshot), do: :ok, else: :degraded
  end

  defp job_reliability_status(_job, _snapshot), do: :ok

  defp publish_job_status(job, :restored, snapshot, state) do
    state.event_bus.publish(job["job_id"], %{
      type: :job_reliability_restored,
      mode: snapshot.mode,
      observed_nodes: snapshot.observed_nodes,
      timestamp: Runtime.timestamp()
    })
  end

  defp publish_job_status(job, :degraded, snapshot, state) do
    state.event_bus.publish(job["job_id"], %{
      type: :job_reliability_degraded,
      mode: snapshot.mode,
      observed_nodes: snapshot.observed_nodes,
      reason: "cluster recovery is not currently reliable",
      timestamp: Runtime.timestamp()
    })
  end

  defp active_job?(%{"status" => status}), do: status in ["pending", "running", "paused"]
  defp active_job?(_job), do: false

  defp schedule_tick(state, delay_ms) do
    state = cancel_tick_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, token}, max(delay_ms, 0))
    %{state | tick_timer_ref: timer_ref, tick_token: token}
  end

  defp cancel_tick_timer(%{tick_timer_ref: ref, tick_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:tick, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_tick_timer(state)
  end

  defp cancel_tick_timer(state), do: state

  defp clear_tick_timer(state),
    do: %{state | tick_timer_ref: nil, tick_token: nil}

  defp interval_ms do
    config_positive_integer(
      "MN_RELIABILITY_OBSERVER_INTERVAL_MS",
      :reliability_observer_interval_ms,
      @default_interval_ms
    )
  end

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> parse_positive_integer(value, default)
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end
end
