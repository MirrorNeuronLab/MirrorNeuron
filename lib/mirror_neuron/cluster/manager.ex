defmodule MirrorNeuron.Cluster.Manager do
  alias MirrorNeuron.Execution.LeaseManager

  def nodes do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.map(fn node ->
      case fetch_node_info(node) do
        {:ok, {lease_stats, hardware_info}} ->
          %{
            name: to_string(node),
            connected_nodes: runtime_connected_nodes(node),
            self?: node == Node.self(),
            scheduler_hint: if(node == Node.self(), do: "cluster_member", else: "remote_member"),
            executor_pools: lease_stats,
            hardware: hardware_info
          }

        {:error, _reason} ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def add_node(node_name) when is_binary(node_name) do
    atom_name = String.to_atom(node_name)

    if Node.connect(atom_name) do
      {:ok, %{name: node_name, status: "connected"}}
    else
      {:error, "failed to connect to #{node_name}"}
    end
  end

  def remove_node(node_name) when is_binary(node_name) do
    atom_name = String.to_atom(node_name)

    if Node.disconnect(atom_name) do
      {:ok, %{name: node_name, status: "disconnected"}}
    else
      # Node.disconnect returns false if node is not connected (ignored or error depending on version)
      {:error, "failed to disconnect from #{node_name} or node not connected"}
    end
  end

  defp fetch_node_info(node) do
    if node == Node.self() do
      {:ok, {LeaseManager.stats(), MirrorNeuron.Cluster.Hardware.info()}}
    else
      case :rpc.call(node, __MODULE__, :local_info, [], 5_000) do
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
    [self_node | Node.list()]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == Node.self() and self_node != Node.self()))
    |> Enum.filter(fn node ->
      case fetch_node_info(node) do
        {:ok, _info} -> true
        {:error, _reason} -> false
      end
    end)
    |> Enum.map(&to_string/1)
  end
end
