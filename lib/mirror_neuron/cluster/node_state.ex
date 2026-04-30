defmodule MirrorNeuron.Cluster.NodeState do
  @moduledoc false

  alias MirrorNeuron.Persistence.RedisStore

  @active_statuses ["healthy", "joining"]
  @inactive_statuses ["draining", "offline", "quarantined"]

  def mark(node, status, attrs \\ %{}) do
    node_name = to_string(node)

    attrs =
      attrs
      |> Map.put("status", to_string(status))
      |> Map.put("node", node_name)

    RedisStore.persist_node_state(node_name, attrs)
  end

  def status(node) do
    case RedisStore.fetch_node_state(to_string(node)) do
      {:ok, %{"status" => status}} -> status
      _ -> default_status(node)
    end
  end

  def active?(node), do: status(node) in @active_statuses
  def inactive?(node), do: status(node) in @inactive_statuses

  def list do
    case RedisStore.list_node_states() do
      {:ok, states} -> states
      {:error, _reason} -> []
    end
  end

  defp default_status(node) do
    if node in [Node.self() | Node.list()], do: "healthy", else: "offline"
  end
end
