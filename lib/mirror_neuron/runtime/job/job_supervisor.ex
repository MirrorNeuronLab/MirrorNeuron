defmodule MirrorNeuron.Runtime.JobSupervisor do
  use Horde.DynamicSupervisor

  # A JobRunner restart is the durable clean-attempt mechanism, so bursts from
  # independent jobs are expected control flow rather than a supervisor fault.
  # Per-job lifecycle policies bound the actual retry loops.
  @max_restarts 10_000
  @max_seconds 5

  def start_link(_init_arg) do
    Horde.DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    [
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds,
      distribution_strategy: MirrorNeuron.Runtime.ProfileDistribution,
      members: MirrorNeuron.Runtime.HordeCluster.initial_members(__MODULE__)
    ]
    |> Horde.DynamicSupervisor.init()
  end
end
