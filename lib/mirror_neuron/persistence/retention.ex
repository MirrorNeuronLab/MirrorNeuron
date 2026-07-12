defmodule MirrorNeuron.Persistence.Retention do
  use GenServer
  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

    state = %{interval_ms: interval_ms}
    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    result = RedisStore.sweep_retention(cleanup_job: &Runtime.cleanup_job_sandboxes/2)

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

    schedule_sweep(state)
    {:noreply, state}
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

  defp schedule_sweep(%{interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :sweep, interval_ms)
    :ok
  end

  defp schedule_sweep(_state), do: :ok

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
