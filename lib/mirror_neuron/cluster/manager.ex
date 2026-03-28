defmodule MirrorNeuron.Cluster.Manager do
  alias MirrorNeuron.Execution.LeaseManager

  def nodes do
    connected = Node.list()

    [Node.self() | connected]
    |> Enum.uniq()
    |> Enum.map(fn node ->
      lease_stats = fetch_lease_stats(node)

      %{
        name: to_string(node),
        connected_nodes: Enum.map(connected, &to_string/1),
        self?: node == Node.self(),
        scheduler_hint: if(node == Node.self(), do: "cluster_member", else: "remote_member"),
        executor_pools: lease_stats
      }
    end)
  end

  defp fetch_lease_stats(node) do
    if node == Node.self() do
      LeaseManager.stats()
    else
      case :rpc.call(node, LeaseManager, :stats, [], 5_000) do
        {:badrpc, reason} -> %{"error" => inspect(reason)}
        stats -> stats
      end
    end
  end
end
