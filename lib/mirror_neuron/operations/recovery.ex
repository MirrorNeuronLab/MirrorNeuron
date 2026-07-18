defmodule MirrorNeuron.Operations.Recovery do
  @moduledoc false

  use GenServer

  alias MirrorNeuron.Operations.Supervisor
  alias MirrorNeuron.Persistence.OperationStore

  @interval_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Process.send_after(self(), :recover, 500)
    {:ok, :ok}
  end

  @impl true
  def handle_info(:recover, state) do
    case OperationStore.list_unfinished() do
      {:ok, operations} -> Enum.each(operations, &Supervisor.start_operation(&1["operation_id"]))
      _ -> :ok
    end

    Process.send_after(self(), :recover, @interval_ms)
    {:noreply, state}
  end
end
