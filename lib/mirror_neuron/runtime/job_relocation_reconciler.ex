defmodule MirrorNeuron.Runtime.JobRelocationReconciler do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    send(self(), :reconcile)
    {:ok, nil}
  end

  def handle_info(:reconcile, state) do
    try do
      MirrorNeuron.Runtime.JobRelocation.reconcile_cleanup()
    rescue
      _ -> Logger.warning("job relocation recovery unavailable; ownership retained")
    catch
      _, _ -> Logger.warning("job relocation recovery unavailable; ownership retained")
    end

    Process.send_after(self(), :reconcile, 30_000)
    {:noreply, state}
  end
end
