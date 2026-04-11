defmodule MirrorNeuron.Application do
  use Application

  alias MirrorNeuron.Config

  @impl true
  def start(_type, _args) do
    cluster_hosts =
      "MIRROR_NEURON_CLUSTER_NODES"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom/1)

    topologies =
      if cluster_hosts == [] do
        []
      else
        [
          mirror_neuron: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: cluster_hosts]
          ]
        ]
      end

    role = node_role()

    api_port = Config.integer("MIRROR_NEURON_API_PORT", :api_port)
    api_enabled? = Config.boolean("MIRROR_NEURON_API_ENABLED", :api_enabled)

    common_children =
      [
        {Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry},
        {Cluster.Supervisor, [topologies, [name: MirrorNeuron.ClusterSupervisor]]},
        MirrorNeuron.Redis
      ] ++ maybe_api_child(api_enabled?, api_port)

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

  defp maybe_api_child(true, api_port) do
    if api_port == 0 or port_available?(api_port) do
      [{Bandit, plug: MirrorNeuron.API.Router, port: api_port}]
    else
      []
    end
  end

  defp maybe_api_child(false, _api_port), do: []

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false

      {:error, _reason} ->
        false
    end
  end
end
