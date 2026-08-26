defmodule MirrorNeuron.Cluster.Manager do
  alias MirrorNeuron.Config
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Persistence.RedisStore

  def nodes do
    ([NodeAdapter.self() | NodeAdapter.list()] ++ federated_node_names())
    |> Enum.uniq()
    |> Enum.map(fn node ->
      state = stored_node_state(node)

      if node != NodeAdapter.self() and NodeState.operator_disconnected_state?(state) do
        nil
      else
        case fetch_node_info(node, state) do
          {:ok, {lease_stats, hardware_info}} ->
            %{
              name: to_string(node),
              display_name: node_display_name(node, state, hardware_info),
              hostname: node_hostname(hardware_info),
              address: Map.get(state, "address") || node_grpc_host(node, state),
              grpc_host: node_grpc_host(node, state),
              grpc_port: Map.get(state, "grpc_port") || node_grpc_port(state),
              native_sdk_grpc: native_sdk_grpc_info(node, state, hardware_info),
              status: Map.get(state, "status", "healthy"),
              scheduling_eligible:
                if(Map.get(state, "connection_mode") == "federated",
                  do: false,
                  else: Map.get(state, "scheduling_eligible", true)
                ),
              local_scheduler_eligible:
                Map.get(state, "local_scheduler_eligible", node == NodeAdapter.self()),
              job_owner_eligible: Map.get(state, "job_owner_eligible", true),
              connection_mode:
                Map.get(
                  state,
                  "connection_mode",
                  if(node == NodeAdapter.self(), do: "local", else: "local_distribution")
                ),
              peer_available: Map.get(state, "peer_available", true),
              litellm: node_litellm(node, state),
              coordination_store: node_coordination_store(node, state),
              drain: Map.get(state, "drain"),
              runtime_status: Map.get(state, "runtime_status", %{}),
              connected_nodes: runtime_connected_nodes(node, state),
              self?: node == NodeAdapter.self(),
              scheduler_hint:
                cond do
                  node == NodeAdapter.self() -> "local_owner"
                  Map.get(state, "connection_mode") == "federated" -> "federated_owner"
                  true -> "remote_member"
                end,
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

  defp fetch_node_info(_node, %{"connection_mode" => "federated"} = state) do
    {:ok, {Map.get(state, "executor_pools", %{}), Map.get(state, "hardware", %{})}}
  end

  defp fetch_node_info(node, _state) do
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
    hardware = MirrorNeuron.Cluster.Hardware.info()
    Map.put(hardware, "native_sdk_grpc", native_sdk_grpc_node_info(hardware))
  end

  defp runtime_connected_nodes(_self_node, %{"connection_mode" => "federated"}), do: []

  defp runtime_connected_nodes(self_node, _state) do
    [self_node | NodeAdapter.list()]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == NodeAdapter.self() and self_node != NodeAdapter.self()))
    |> Enum.map(&to_string/1)
  end

  defp federated_node_names do
    NodeState.list()
    |> Enum.filter(fn state ->
      Map.get(state, "connection_mode") == "federated" and
        not NodeState.operator_disconnected_state?(state)
    end)
    |> Enum.map(&(Map.get(&1, "node") || Map.get(&1, "name")))
    |> Enum.reject(&is_nil/1)
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

  defp node_grpc_host(node, state) do
    Map.get(state, "grpc_host") ||
      if(node == NodeAdapter.self(),
        do:
          Config.optional_string(
            "MN_NETWORK_ADVERTISE_HOST",
            :network_advertise_host
          ),
        else: nil
      ) ||
      node_host(node)
  end

  defp native_sdk_grpc_info(node, state, hardware) do
    Map.get(state, "native_sdk_grpc") ||
      Map.get(state, :native_sdk_grpc) ||
      Map.get(hardware, "native_sdk_grpc") ||
      Map.get(hardware, :native_sdk_grpc) ||
      if(node == NodeAdapter.self(), do: native_sdk_grpc_node_info(hardware), else: nil)
  end

  defp native_sdk_grpc_node_info(hardware) do
    advertised =
      Map.get(hardware, "native_sdk_grpc") || Map.get(hardware, :native_sdk_grpc) || %{}

    host =
      Config.optional_string(
        "MN_NATIVE_SDK_GRPC_ADVERTISE_HOST",
        :native_sdk_grpc_advertise_host
      ) ||
        Config.optional_string("MN_NETWORK_ADVERTISE_HOST", :network_advertise_host) ||
        Map.get(advertised, "host") ||
        Map.get(advertised, :host) ||
        node_host(NodeAdapter.self())

    port =
      Config.optional_string(
        "MN_NATIVE_SDK_GRPC_ADVERTISE_PORT",
        :native_sdk_grpc_advertise_port
      ) ||
        Map.get(advertised, "port") ||
        Map.get(advertised, :port) ||
        native_sdk_grpc_port()

    target = if host in [nil, ""], do: "", else: "#{host}:#{port}"

    %{
      "enabled" => host not in [nil, ""] and port not in [nil, ""],
      "host" => host || "",
      "port" => port,
      "target" => target,
      "bind_host" =>
        Config.optional_string("MN_NATIVE_SDK_GRPC_HOST", :native_sdk_grpc_host) ||
          Map.get(advertised, "bind_host") ||
          Map.get(advertised, :bind_host) ||
          "",
      "capabilities" =>
        Map.get(advertised, "capabilities") || Map.get(advertised, :capabilities) || []
    }
  end

  defp native_sdk_grpc_port do
    Config.optional_string(
      "MN_NATIVE_SDK_GRPC_ADVERTISE_PORT",
      :native_sdk_grpc_advertise_port
    ) ||
      Config.optional_string("MN_NATIVE_SDK_GRPC_PORT", :native_sdk_grpc_port) ||
      "55052"
  end

  defp node_coordination_store(node, state) do
    if node == NodeAdapter.self() do
      case coordination_store().coordination_store_status() do
        {:ok, status} -> status
        _ -> %{}
      end
    else
      Map.get(state, "coordination_store", %{})
    end
  end

  defp node_litellm(node, state) do
    if node == NodeAdapter.self() do
      host =
        Config.optional_string("MN_LITELLM_ADVERTISE_HOST", :litellm_advertise_host) ||
          Config.optional_string("MN_NETWORK_ADVERTISE_HOST", :network_advertise_host) ||
          node_host(node)

      port =
        Config.optional_string("MN_LITELLM_ADVERTISE_PORT", :litellm_advertise_port) ||
          Config.optional_string("MN_LITELLM_GATEWAY_PORT", :litellm_gateway_port) ||
          "4000"

      %{
        "enabled" => host not in [nil, ""],
        "host" => host || "",
        "port" => parse_grpc_port(port),
        "url" => if(host in [nil, ""], do: "", else: "http://#{host}:#{port}")
      }
    else
      Map.get(state, "litellm", %{})
    end
  end

  defp coordination_store do
    Application.get_env(:mirror_neuron, :coordination_store, RedisStore)
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
