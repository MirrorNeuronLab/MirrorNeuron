defmodule MirrorNeuron.Runtime.JobResponseReconciler do
  @moduledoc false
  use GenServer

  alias MirrorNeuron.Runtime.JobResponse
  alias MirrorNeuron.Runtime.StableJob

  @interval_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def reconcile_async do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :reconcile)
    :ok
  end

  @impl true
  def init(:ok) do
    send(self(), :reconcile)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:reconcile, state) do
    reconcile()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    Process.send_after(self(), :reconcile, @interval_ms)
    {:noreply, state}
  end

  defp reconcile do
    case StableJob.list(include_archived: true) do
      {:ok, definitions} -> Enum.each(definitions, &JobResponse.ensure_started/1)
      _ -> :ok
    end
  end
end
