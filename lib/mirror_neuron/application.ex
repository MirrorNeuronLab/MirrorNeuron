defmodule MirrorNeuron.Application do
  use Application

  alias MirrorNeuron.Config

  @impl true
  def start(_type, _args) do
    Config.validate!()

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

    grpc_port = String.to_integer(System.get_env("MIRROR_NEURON_GRPC_PORT", "50051"))
    grpc_host = System.get_env("MIRROR_NEURON_CORE_HOST", "localhost")
    grpc_bind_opts = grpc_bind_opts(grpc_host)

    common_children =
      [
        {Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry},
        {Cluster.Supervisor, [topologies, [name: MirrorNeuron.ClusterSupervisor]]},
        MirrorNeuron.Redis,
        {GRPC.Server.Supervisor,
         [endpoint: MirrorNeuron.Grpc.Endpoint, port: grpc_port, start_server: true] ++
           grpc_bind_opts}
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

  defp grpc_bind_opts(host) when host in ["", "localhost"] do
    [ip: {127, 0, 0, 1}]
  end

  defp grpc_bind_opts(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 4 ->
        [ip: address]

      {:ok, address} when tuple_size(address) == 8 ->
        [net: :inet6, ip: address]

      _ ->
        []
    end
  end
end
