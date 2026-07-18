defmodule MirrorNeuron.Operations.Supervisor do
  @moduledoc false

  use Supervisor

  alias MirrorNeuron.Operations.Runner

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def start_operation(operation_id) do
    case DynamicSupervisor.start_child(
           MirrorNeuron.Operations.RunnerSupervisor,
           {Runner, operation_id}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(:ok) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: MirrorNeuron.Operations.RunnerSupervisor},
      MirrorNeuron.Operations.Recovery
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
