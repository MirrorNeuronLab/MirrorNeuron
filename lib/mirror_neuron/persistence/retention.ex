defmodule MirrorNeuron.Persistence.Retention do
  use GenServer
  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(opts, :interval_ms) ||
        config_integer(
          "MN_RETENTION_GC_INTERVAL_MS",
          :retention_gc_interval_ms,
          @default_interval_ms
        )

    state = %{interval_ms: interval_ms, sweep_timer_ref: nil, sweep_token: nil}
    {:ok, schedule_sweep(state)}
  end

  @impl true
  def handle_info({:sweep, token}, %{sweep_token: token} = state) do
    state = clear_sweep_timer(state)
    run_sweep()
    {:noreply, schedule_sweep(state)}
  end

  def handle_info({:sweep, _stale_token}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    run_sweep()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_sweep_timer(state)
    :ok
  end

  defp run_sweep do
    result = RedisStore.sweep_retention(cleanup_job: &Runtime.cleanup_job_resources/2)

    case result do
      {:ok, %{deleted_count: deleted_count, stale_count: stale_count}}
      when deleted_count > 0 or stale_count > 0 ->
        Logger.debug(
          "retention sweep removed #{deleted_count} jobs and #{stale_count} stale job ids"
        )

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("retention sweep failed: #{inspect(reason)}")
    end

    if match?({:ok, _result}, result), do: sweep_bundle_retention()

    :ok
  end

  defp sweep_bundle_retention do
    case Archive.sweep_retention() do
      {:ok, %{reclaimed_bundle_cache_count: count}} when count > 0 ->
        Logger.debug("retention sweep reclaimed #{count} bundle cache entries")

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("bundle retention sweep deferred: #{inspect(reason)}")
    end
  end

  defp schedule_sweep(%{interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    state = cancel_sweep_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:sweep, token}, interval_ms)
    %{state | sweep_timer_ref: timer_ref, sweep_token: token}
  end

  defp schedule_sweep(state), do: cancel_sweep_timer(state)

  defp cancel_sweep_timer(%{sweep_timer_ref: ref, sweep_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:sweep, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_sweep_timer(state)
  end

  defp cancel_sweep_timer(state), do: state

  defp clear_sweep_timer(state),
    do: %{state | sweep_timer_ref: nil, sweep_token: nil}

  defp config_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil ->
        Application.get_env(:mirror_neuron, key, default)

      "" ->
        Application.get_env(:mirror_neuron, key, default)

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end
end
