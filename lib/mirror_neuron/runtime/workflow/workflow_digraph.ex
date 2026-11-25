defmodule MirrorNeuron.Runtime.WorkflowDigraph do
  @moduledoc false

  # The ledger keeps plain data. This private graph lives only for one validation.
  def validate(step_ids, edges, check \\ fn _graph -> :ok end) do
    graph = :digraph.new([:private])

    try do
      Enum.each(step_ids, &:digraph.add_vertex(graph, &1))

      with :ok <- add_edges(graph, edges) do
        if :digraph_utils.is_acyclic(graph), do: check.(graph), else: {:error, :cycle}
      end
    after
      :digraph.delete(graph)
    end
  end

  defp add_edges(graph, edges) do
    Enum.reduce_while(edges, :ok, fn {from, to}, :ok ->
      case :digraph.add_edge(graph, from, to) do
        {:error, {:bad_vertex, _}} -> {:halt, {:error, :dangling_edge}}
        _edge_id -> {:cont, :ok}
      end
    end)
  end
end
