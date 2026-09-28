defmodule MirrorNeuron.Runtime.InteractionDeadlines do
  @moduledoc false
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts) do
    Process.send_after(self(), :expire, 250)
    {:ok, nil}
  end
  @impl true
  def handle_info(:expire, state) do
    MirrorNeuron.Persistence.InteractionStore.expire_due()
    Process.send_after(self(), :expire, 250)
    {:noreply, state}
  end
end
