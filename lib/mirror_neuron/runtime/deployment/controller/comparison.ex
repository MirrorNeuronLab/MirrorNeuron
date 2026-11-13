defmodule MirrorNeuron.Runtime.DeploymentController.Comparison do
  @moduledoc "Compares logical topology and maps changed source nodes to runtime agents."

  alias MirrorNeuron.Manifest

  def same_topology?(%Manifest{} = left, %Manifest{} = right) do
    topology_signature(left) == topology_signature(right)
  end

  defp topology_signature(manifest) do
    %{
      nodes: Enum.map(manifest.nodes, & &1.node_id) |> Enum.sort(),
      edges:
        manifest.edges
        |> Enum.map(&{&1.from_node, &1.to_node, &1.message_type, &1.routing_mode})
        |> Enum.sort(),
      entrypoints: Enum.sort(manifest.entrypoints || [])
    }
  end

  def changed_source_agent_ids(old_manifest, new_manifest) do
    old_nodes = Map.new(old_manifest.nodes, &{&1.node_id, node_compare_map(&1)})

    new_manifest.nodes
    |> Enum.filter(fn node -> Map.get(old_nodes, node.node_id) != node_compare_map(node) end)
    |> Enum.map(& &1.node_id)
  end

  defp node_compare_map(node) do
    node
    |> Map.take([:agent_type, :type, :role, :config, :resources, :constraints, :services])
    |> json_safe()
  end

  def runtime_agent_ids(scheduler_plan, source_agent_ids) do
    source_set = MapSet.new(source_agent_ids)
    placements = Map.get(scheduler_plan, "placements", [])

    case placements do
      [] ->
        source_agent_ids

      placements ->
        placements
        |> Enum.filter(fn placement ->
          MapSet.member?(source_set, placement["source_agent_id"] || placement["agent_id"])
        end)
        |> Enum.map(& &1["agent_id"])
        |> Enum.reject(&is_nil/1)
    end
  end

  defp json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, json_safe(value)}
    end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(value), do: value
end
