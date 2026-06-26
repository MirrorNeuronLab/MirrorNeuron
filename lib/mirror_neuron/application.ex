defmodule MirrorNeuron.Application do
  use Application

  require Logger

  alias MirrorNeuron.Config

  @impl true
  def start(_type, _args) do
    Config.validate!()

    cluster_hosts =
      "MN_CLUSTER_NODES"
      |> Config.string(:cluster_nodes)
      |> String.split(",", trim: true)
      |> Enum.map(&MirrorNeuron.SafeAccess.node_name_to_atom!/1)

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

    common_children =
      [
        {Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry},
        {Cluster.Supervisor, [topologies, [name: MirrorNeuron.ClusterSupervisor]]},
        MirrorNeuron.Redis,
        MirrorNeuron.Persistence.Retention
      ] ++ grpc_child_specs()

    children =
      case role do
        "control" ->
          common_children

        _ ->
          common_children ++
            [
              MirrorNeuron.Cluster.NodeMonitor,
              MirrorNeuron.Cluster.Leader,
              MirrorNeuron.Runtime.ReliabilityObserver,
              MirrorNeuron.Execution.LeaseManager,
              {Registry, keys: :unique, name: MirrorNeuron.Sandbox.Registry},
              {DynamicSupervisor,
               strategy: :one_for_one, name: MirrorNeuron.Sandbox.JobSandboxSupervisor},
              MirrorNeuron.DistributedRegistry,
              MirrorNeuron.Runtime.JobSupervisor,
              MirrorNeuron.Runtime.AgentSupervisor,
              {Task.Supervisor, name: MirrorNeuron.Runtime.RecoveryTaskSupervisor},
              MirrorNeuron.ServiceMonitor,
              MirrorNeuron.Bundle.Manager,
              MirrorNeuron.Runtime.LocalRecovery,
              MirrorNeuron.Bundle.Scanner
            ]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: MirrorNeuron.Supervisor)
  end

  def node_role do
    Config.string("MN_NODE_ROLE", :node_role)
  end

  @doc false
  def grpc_child_specs do
    grpc_port = Config.integer("MN_GRPC_PORT", :grpc_port)
    grpc_host = Config.string("MN_CORE_HOST", :core_host)

    [
      {GRPC.Server.Supervisor,
       [endpoint: MirrorNeuron.Grpc.Endpoint, port: grpc_port, start_server: true] ++
         grpc_bind_opts(grpc_host)}
    ]
  end

  def grpc_bind_opts(host) do
    normalized_host =
      host
      |> to_string()
      |> String.trim()

    case normalized_host do
      "" ->
        [ip: {127, 0, 0, 1}]

      host ->
        parse_grpc_bind_host(host)
    end
  end

  defp parse_grpc_bind_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 4 ->
        [ip: address]

      {:ok, address} when tuple_size(address) == 8 ->
        [net: :inet6, ip: address]

      _ ->
        grpc_loopback_opts(host)
    end
  end

  defp grpc_loopback_opts(host) do
    unless String.downcase(host) == "localhost" do
      Logger.warning("Invalid MN_CORE_HOST #{inspect(host)}; binding gRPC listener to 127.0.0.1")
    end

    [ip: {127, 0, 0, 1}]
  end
end
