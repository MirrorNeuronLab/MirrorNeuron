defmodule MirrorNeuron.Runtime.JobTopology do
  @moduledoc false

  # Pure expansion and projection of a scheduled manifest. The coordinator owns
  # lifecycle transitions and when these derived values enter its state.
  def build(manifest, scheduler_plan) do
    job_type = scheduler_plan["job_type"]
    placements = Map.get(scheduler_plan, "placements", [])

    if job_type in ["system", "sysbatch"] and placements != [] do
      build_system_runtime_topology(manifest, scheduler_plan, placements)
    else
      %{
        nodes: manifest.nodes,
        edges: manifest.edges,
        entrypoints: manifest.entrypoints,
        agent_ids: Enum.map(manifest.nodes, & &1.node_id),
        source_agent_ids: Map.new(manifest.nodes, &{&1.node_id, &1.node_id}),
        system_targets: [],
        agents_by_system_target: %{}
      }
    end
  end

  defp build_system_runtime_topology(manifest, scheduler_plan, placements) do
    source_nodes = Map.new(manifest.nodes, &{&1.node_id, &1})

    runtime_nodes =
      placements
      |> Enum.map(fn placement ->
        source_agent_id = placement["source_agent_id"] || placement["agent_id"]
        source_node = Map.fetch!(source_nodes, source_agent_id)
        target = placement["system_target"] || placement["node"]

        config =
          source_node.config
          |> Map.put("__mirror_neuron_source_node_id", source_agent_id)
          |> Map.put("__mirror_neuron_system_target", target)

        %{source_node | node_id: placement["agent_id"], config: config}
      end)

    system_targets =
      scheduler_plan
      |> Map.get("system_targets", [])
      |> case do
        [] ->
          placements
          |> Enum.map(&(&1["system_target"] || &1["node"]))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        targets ->
          targets
      end

    runtime_edges =
      for target <- system_targets,
          edge <- manifest.edges do
        %{
          edge
          | from_node: system_agent_id(edge.from_node, target),
            to_node: system_agent_id(edge.to_node, target)
        }
      end

    entrypoints =
      for target <- system_targets,
          entrypoint <- manifest.entrypoints do
        system_agent_id(entrypoint, target)
      end

    source_agent_ids =
      Map.new(placements, fn placement ->
        {placement["agent_id"], placement["source_agent_id"] || placement["agent_id"]}
      end)

    agents_by_system_target =
      placements
      |> Enum.group_by(&(&1["system_target"] || &1["node"]), & &1["agent_id"])
      |> Enum.reject(fn {target, _agents} -> is_nil(target) end)
      |> Map.new()

    %{
      nodes: runtime_nodes,
      edges: runtime_edges,
      entrypoints: entrypoints,
      agent_ids: Enum.map(runtime_nodes, & &1.node_id),
      source_agent_ids: source_agent_ids,
      system_targets: system_targets,
      agents_by_system_target: agents_by_system_target
    }
  end

  def snapshot(state) do
    %{
      "nodes" =>
        Enum.map(state.runtime_nodes, fn node ->
          %{
            "node_id" => node.node_id,
            "source_node_id" => Map.get(state.source_agent_ids, node.node_id, node.node_id),
            "agent_type" => node.agent_type,
            "type" => node.type,
            "role" => node.role,
            "system_target" => get_in(node.config, ["__mirror_neuron_system_target"])
          }
        end),
      "edges" =>
        Enum.map(state.runtime_edges, fn edge ->
          %{
            "edge_id" => edge.edge_id,
            "from_node" => edge.from_node,
            "to_node" => edge.to_node,
            "message_type" => edge.message_type,
            "routing_mode" => edge.routing_mode,
            "conditions" => edge.conditions
          }
        end),
      "entrypoints" => state.runtime_entrypoints,
      "system_targets" => state.system_targets
    }
  end

  defp system_agent_id(agent_id, target_node), do: "#{agent_id}@#{target_node}"

  def downstream_index(edges) do
    direct = Enum.group_by(edges, & &1.from_node, & &1.to_node)

    direct
    |> Map.keys()
    |> Enum.into(%{}, fn node_id ->
      {node_id, downstream_closure(node_id, direct, MapSet.new())}
    end)
  end

  defp downstream_closure(node_id, direct, visited) do
    direct
    |> Map.get(node_id, [])
    |> Enum.reject(&MapSet.member?(visited, &1))
    |> Enum.flat_map(fn child ->
      [child | downstream_closure(child, direct, MapSet.put(visited, child))]
    end)
    |> Enum.uniq()
  end
end
