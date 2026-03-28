defmodule MirrorNeuron.Application do
  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      {Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry},
      {Cluster.Supervisor, [topologies, [name: MirrorNeuron.ClusterSupervisor]]},
      MirrorNeuron.Redis,
      MirrorNeuron.Execution.LeaseManager,
      MirrorNeuron.DistributedRegistry,
      MirrorNeuron.Runtime.JobSupervisor,
      MirrorNeuron.Runtime.AgentSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MirrorNeuron.Supervisor)
  end
end
