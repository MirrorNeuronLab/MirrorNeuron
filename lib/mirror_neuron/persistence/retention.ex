defmodule MirrorNeuron.Persistence.Retention do
  use GenServer
  require Logger

  alias MirrorNeuron.Persistence.RedisStore

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
    case RedisStore.sweep_retention() do
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

    schedule_sweep(state)
    {:noreply, state}
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
