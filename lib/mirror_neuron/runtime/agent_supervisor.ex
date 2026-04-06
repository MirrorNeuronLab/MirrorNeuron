defmodule MirrorNeuron.Runtime.AgentSupervisor do
  use Horde.DynamicSupervisor

  def start_link(_init_arg) do
    Horde.DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    [
      strategy: :one_for_one,
      distribution_strategy: Horde.UniformDistribution,
      members: :auto
    ]
    |> Horde.DynamicSupervisor.init()
  end
end
