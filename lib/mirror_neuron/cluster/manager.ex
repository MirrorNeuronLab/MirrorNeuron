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
    atom_name = String.to_atom(node_name)

    if NodeAdapter.connect(atom_name) do
      NodeState.mark_connected(node_name, %{
        "operator_disconnect" => false,
        "scheduling_eligible" => true
      })

      {:ok, %{name: node_name, status: "connected"}}
    else
      {:error, "failed to connect to #{node_name}"}
    end
  end

  def remove_node(node_name) when is_binary(node_name) do
    atom_name = String.to_atom(node_name)

    NodeState.mark(node_name, "disconnected", %{
      "operator_disconnect" => true,
      "scheduling_eligible" => false,
      "reason" => "operator requested disconnect"
    })

    if NodeAdapter.disconnect(atom_name) do
      {:ok, %{name: node_name, status: "disconnected"}}
    else
      {:ok, %{name: node_name, status: "disconnected"}}
    end
  end

  defp fetch_node_info(node) do
    if node == NodeAdapter.self() do
      {:ok, {LeaseManager.stats(), MirrorNeuron.Cluster.Hardware.info()}}
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
    {LeaseManager.stats(), MirrorNeuron.Cluster.Hardware.info()}
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
end
