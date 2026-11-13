defmodule MirrorNeuron.Runtime.LocalRecovery do
  use GenServer
  @moduledoc "Supervised periodic local recovery with one tokenized scan timer."

  alias MirrorNeuron.Runtime.LocalRecovery.Scan
  alias MirrorNeuron.Runtime.LocalRecovery.Settings

  defdelegate recover_unfinished_jobs(), to: Scan
  defdelegate recover_unfinished_jobs(opts), to: Scan
  defdelegate recover_job(job_id), to: Scan
  defdelegate recover_job(job_id, opts), to: Scan

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def scan(opts \\ []) do
    scan(__MODULE__, opts)
  end

  def scan(server, opts) do
    GenServer.call(server, {:scan, opts}, 30_000)
  end

  @impl true
  def init(opts) do
    state = %{
      scan_interval_ms: Keyword.get(opts, :scan_interval_ms, Settings.scan_interval_ms()),
      repair_indexes_on_next_scan: true,
      scan_timer_ref: nil,
      scan_token: nil
    }

    state =
      if Settings.enabled?() do
        schedule_scan(state, Keyword.get(opts, :startup_delay_ms, Settings.startup_delay_ms()))
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:scan, token}, %{scan_token: token} = state) do
    state = clear_scan_timer(state)
    state = run_periodic_scan(state)
    {:noreply, schedule_scan(state, state.scan_interval_ms)}
  end

  def handle_info({:scan, _stale_token}, state), do: {:noreply, state}

  def handle_info(:scan, state), do: {:noreply, run_periodic_scan(state)}

  @impl true
  def terminate(_reason, state) do
    cancel_scan_timer(state)
    :ok
  end

  defp run_periodic_scan(state) do
    _ =
      Scan.recover_unfinished_jobs(
        reason: "startup_or_periodic_scan",
        repair_indexes?: state.repair_indexes_on_next_scan
      )

    %{state | repair_indexes_on_next_scan: false}
  end

  @impl true
  def handle_call({:scan, opts}, _from, state) do
    {:reply, Scan.recover_unfinished_jobs(opts), state}
  end

  defp schedule_scan(state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    state = cancel_scan_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:scan, token}, delay_ms)
    %{state | scan_timer_ref: timer_ref, scan_token: token}
  end

  defp schedule_scan(state, _delay_ms), do: cancel_scan_timer(state)

  defp cancel_scan_timer(%{scan_timer_ref: ref, scan_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:scan, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_scan_timer(state)
  end

  defp cancel_scan_timer(state), do: state

  defp clear_scan_timer(state),
    do: %{state | scan_timer_ref: nil, scan_token: nil}
end
