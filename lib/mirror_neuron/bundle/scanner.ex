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
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # bundle_id => last_checked_system_time
    state = %{
      last_checked: %{},
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      tick_timer_ref: nil,
      tick_token: nil
    }

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_info({:tick, token}, %{tick_token: token} = state) do
    state = clear_tick_timer(state)
    state = scan_bundles(state)
    {:noreply, schedule_tick(state)}
  end

  def handle_info({:tick, _stale_token}, state), do: {:noreply, state}

  def handle_info(:tick, state), do: {:noreply, scan_bundles(state)}

  @impl true
  def terminate(_reason, state) do
    cancel_tick_timer(state)
    :ok
  end

  defp scan_bundles(state) do
    bundles = Manager.list_bundles()
    now_ms = System.monotonic_time(:millisecond)
    bundle_ids = Enum.map(bundles, & &1.bundle_id)
    last_checked = Map.take(state.last_checked, bundle_ids)

    new_last_checked =
      Enum.reduce(bundles, last_checked, fn record, acc ->
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

    %{state | last_checked: new_last_checked}
  end

  defp schedule_tick(%{tick_ms: tick_ms} = state) when is_integer(tick_ms) and tick_ms > 0 do
    state = cancel_tick_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, token}, tick_ms)
    %{state | tick_timer_ref: timer_ref, tick_token: token}
  end

  defp schedule_tick(state), do: cancel_tick_timer(state)

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
end
