defmodule MirrorNeuron.Bundle.Scanner do
  @moduledoc """
  Periodically scans bundles registered in Manager that are set to "interval" mode
  and triggers reloads if their fingerprint changed.
  """
  use GenServer
  require Logger

  alias MirrorNeuron.Bundle.Manager

  # Default base tick for checking interval bundles
  @tick_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    # bundle_id => last_checked_system_time
    {:ok, %{last_checked: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    bundles = Manager.list_bundles()
    now_ms = System.monotonic_time(:millisecond)

    new_last_checked =
      Enum.reduce(bundles, state.last_checked, fn record, acc ->
        manifest = record.bundle_struct.manifest
        mode = manifest.reload.mode
        interval_ms = manifest.reload.interval_seconds * 1000

        if mode == "interval" do
          last = Map.get(acc, record.bundle_id, 0)

          if now_ms - last >= interval_ms do
            # Time to check!
            case Manager.reload(record.bundle_id, "interval_scan") do
              {:ok, %{changed: true} = resp} ->
                Logger.info("Scanner reloaded bundle #{record.bundle_id}: #{inspect(resp)}")

              _ ->
                :ok
            end

            Map.put(acc, record.bundle_id, now_ms)
          else
            acc
          end
        else
          acc
        end
      end)

    schedule_tick()
    {:noreply, %{state | last_checked: new_last_checked}}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end
end
