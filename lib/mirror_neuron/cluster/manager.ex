defmodule MirrorNeuron.Cluster.Manager do
  alias MirrorNeuron.Execution.LeaseManager

  def nodes do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.map(fn node ->
      case fetch_lease_stats(node) do
        {:ok, lease_stats} ->
          %{
            name: to_string(node),
            connected_nodes: runtime_connected_nodes(node),
            self?: node == Node.self(),
            scheduler_hint: if(node == Node.self(), do: "cluster_member", else: "remote_member"),
            executor_pools: lease_stats
          }

        {:error, _reason} ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_lease_stats(node) do
    if node == Node.self() do
      {:ok, LeaseManager.stats()}
    else
      case :rpc.call(node, LeaseManager, :stats, [], 5_000) do
        {:badrpc, reason} -> {:error, inspect(reason)}
        stats when is_map(stats) -> {:ok, stats}
        other -> {:error, inspect(other)}
      end
    end
  end

  defp runtime_connected_nodes(self_node) do
    [self_node | Node.list()]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == Node.self() and self_node != Node.self()))
    |> Enum.filter(fn node ->
      case fetch_lease_stats(node) do
        {:ok, _stats} -> true
        {:error, _reason} -> false
      end
    end)
    |> Enum.map(&to_string/1)
  end
end
