defmodule MirrorNeuron.Cluster.Manager do
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Execution.LeaseManager

  def nodes do
    [NodeAdapter.self() | NodeAdapter.list()]
    |> Enum.uniq()
    |> Enum.map(fn node ->
      state = stored_node_state(node)

      if node != NodeAdapter.self() and NodeState.operator_disconnected_state?(state) do
        nil
      else
        case fetch_node_info(node) do
          {:ok, {lease_stats, hardware_info}} ->
            %{
              name: to_string(node),
              display_name: node_display_name(node, state, hardware_info),
              hostname: node_hostname(hardware_info),
              address: Map.get(state, "address") || node_host(node),
              grpc_host: Map.get(state, "grpc_host") || node_host(node),
              grpc_port: Map.get(state, "grpc_port") || node_grpc_port(state),
              native_sdk_grpc: native_sdk_grpc_info(node, state, hardware_info),
              status: Map.get(state, "status", "healthy"),
              scheduling_eligible: Map.get(state, "scheduling_eligible", true),
              drain: Map.get(state, "drain"),
              connected_nodes: runtime_connected_nodes(node),
              self?: node == NodeAdapter.self(),
              scheduler_hint:
                if(node == NodeAdapter.self(), do: "cluster_member", else: "remote_member"),
              executor_pools: lease_stats,
              hardware: hardware_info
            }

          {:error, _reason} ->
            nil
        end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def add_node(node_name) when is_binary(node_name) do
    with {:ok, atom_name} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name),
         true <- NodeAdapter.connect(atom_name) do
      NodeState.mark_connected(node_name, %{
        "operator_disconnect" => false,
        "scheduling_eligible" => true
      })

      {:ok, %{name: node_name, status: "connected"}}
    else
      false -> {:error, "failed to connect to #{node_name}"}
      {:error, reason} -> {:error, "invalid node name #{inspect(node_name)}: #{reason}"}
    end
  end

  def remove_node(node_name) when is_binary(node_name) do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, atom_name} ->
        NodeState.mark(node_name, "disconnected", %{
          "operator_disconnect" => true,
          "scheduling_eligible" => false,
          "reason" => "operator requested disconnect"
        })

        _ = NodeAdapter.disconnect(atom_name)
        {:ok, %{name: node_name, status: "disconnected"}}

      {:error, reason} ->
        {:error, "invalid node name #{inspect(node_name)}: #{reason}"}
    end
  end

  defp fetch_node_info(node) do
    if node == NodeAdapter.self() do
      {:ok, {LeaseManager.stats(), local_hardware_info()}}
    else
      case NodeAdapter.rpc_call(node, __MODULE__, :local_info, [], 5_000) do
        {:badrpc, reason} -> {:error, inspect(reason)}
        {stats, hw} when is_map(stats) and is_map(hw) -> {:ok, {stats, hw}}
        other -> {:error, inspect(other)}
      end
    end
  end

  @doc false
  def local_info do
    {LeaseManager.stats(), local_hardware_info()}
  end

  defp local_hardware_info do
    MirrorNeuron.Cluster.Hardware.info()
    |> Map.put("native_sdk_grpc", native_sdk_grpc_node_info())
  end

  defp runtime_connected_nodes(self_node) do
    [self_node | NodeAdapter.list()]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == NodeAdapter.self() and self_node != NodeAdapter.self()))
    |> Enum.map(&to_string/1)
  end

  defp stored_node_state(node) do
    case NodeState.fetch(to_string(node)) do
      {:ok, state} when is_map(state) -> state
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp node_display_name(node, state, hardware) do
    Map.get(state, "display_name") ||
      get_in(hardware, [:platform, :display_name]) ||
      get_in(hardware, ["platform", "display_name"]) ||
      node_hostname(hardware) ||
      node |> to_string() |> String.split("@", parts: 2) |> List.last()
  end

  defp node_hostname(hardware) do
    get_in(hardware, [:platform, :hostname]) || get_in(hardware, ["platform", "hostname"])
  end

  defp node_host(node) do
    node
    |> to_string()
    |> String.split("@", parts: 2)
    |> case do
      [_name, host] -> host
      _ -> nil
    end
  end

  defp node_grpc_port(state) do
    Map.get(state, "grpc_port") ||
      advertised_grpc_port()
  end

  defp native_sdk_grpc_info(node, state, hardware) do
    Map.get(state, "native_sdk_grpc") ||
      Map.get(state, :native_sdk_grpc) ||
      Map.get(hardware, "native_sdk_grpc") ||
      Map.get(hardware, :native_sdk_grpc) ||
      if(node == NodeAdapter.self(), do: native_sdk_grpc_node_info(), else: nil)
  end

  defp native_sdk_grpc_node_info do
    host =
      System.get_env("MN_NATIVE_SDK_GRPC_ADVERTISE_HOST") ||
        System.get_env("MN_NETWORK_ADVERTISE_HOST") ||
        node_host(NodeAdapter.self())

    port = native_sdk_grpc_port()
    target = if host in [nil, ""], do: "", else: "#{host}:#{port}"

    %{
      "enabled" => host not in [nil, ""] and port not in [nil, ""],
      "host" => host || "",
      "port" => port,
      "target" => target,
      "bind_host" => System.get_env("MN_NATIVE_SDK_GRPC_HOST") || ""
    }
  end

  defp native_sdk_grpc_port do
    System.get_env("MN_NATIVE_SDK_GRPC_ADVERTISE_PORT") ||
      System.get_env("MN_NATIVE_SDK_GRPC_PORT") ||
      "55052"
  end

  defp advertised_grpc_port do
    case System.get_env("MN_GRPC_ADVERTISE_PORT") do
      nil -> MirrorNeuron.Config.integer("MN_GRPC_PORT", :grpc_port)
      "" -> MirrorNeuron.Config.integer("MN_GRPC_PORT", :grpc_port)
      value -> parse_grpc_port(value)
    end
  end

  defp parse_grpc_port(value) do
    case Integer.parse(value) do
      {port, ""} -> port
      _ -> MirrorNeuron.Config.integer("MN_GRPC_PORT", :grpc_port)
    end
  end
end
