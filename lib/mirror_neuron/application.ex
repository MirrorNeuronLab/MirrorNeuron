defmodule MirrorNeuron.Application do
  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])
    role = node_role()

    api_port = String.to_integer(System.get_env("MIRROR_NEURON_API_PORT", "4000"))

    common_children = [
      {Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry},
      {Cluster.Supervisor, [topologies, [name: MirrorNeuron.ClusterSupervisor]]},
      MirrorNeuron.Redis,
      {Bandit, plug: MirrorNeuron.API.Router, port: api_port}
    ]

    children =
      case role do
        "control" ->
          common_children

        _ ->
          common_children ++
            [
              MirrorNeuron.Cluster.NodeMonitor,
              MirrorNeuron.Cluster.Leader,
              MirrorNeuron.Execution.LeaseManager,
              {Registry, keys: :unique, name: MirrorNeuron.Sandbox.Registry},
              {DynamicSupervisor,
               strategy: :one_for_one, name: MirrorNeuron.Sandbox.JobSandboxSupervisor},
              MirrorNeuron.DistributedRegistry,
              MirrorNeuron.Runtime.JobSupervisor,
              MirrorNeuron.Runtime.AgentSupervisor,
              MirrorNeuron.Bundle.Manager,
              MirrorNeuron.Bundle.Scanner
            ]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: MirrorNeuron.Supervisor)
  end

  def node_role do
    System.get_env("MIRROR_NEURON_NODE_ROLE", "runtime")
  end
end
