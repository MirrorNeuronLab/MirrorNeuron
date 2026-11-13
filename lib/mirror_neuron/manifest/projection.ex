defmodule MirrorNeuron.Manifest.Projection do
  @moduledoc "Serializes manifests and projects physical topology without losing extension fields."

  alias MirrorNeuron.Manifest.Values

  def topology(%MirrorNeuron.Manifest{} = manifest) do
    %{
      "nodes" =>
        Enum.map(manifest.nodes, fn node ->
          %{
            "node_id" => node.node_id,
            "agent_type" => node.agent_type,
            "type" => node.type,
            "role" => node.role
          }
        end),
      "edges" =>
        Enum.map(manifest.edges, fn edge ->
          %{
            "edge_id" => edge.edge_id,
            "from_node" => edge.from_node,
            "to_node" => edge.to_node,
            "message_type" => edge.message_type,
            "routing_mode" => edge.routing_mode,
            "conditions" => Values.json_safe(edge.conditions)
          }
        end)
    }
  end

  def to_map(%MirrorNeuron.Manifest{} = manifest) do
    Values.json_safe(manifest.extensions || %{})
    |> maybe_put("apiVersion", manifest.api_version)
    |> maybe_put("kind", manifest.kind)
    |> Map.merge(%{
      "manifest_version" => manifest.manifest_version,
      "type" => manifest.type,
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "required_context_engine" => manifest.required_context_engine,
      "requirements" => Values.json_safe(manifest.requirements),
      "skill_dependencies" => Values.json_safe(manifest.skill_dependencies),
      "input_validation" => Values.json_safe(manifest.input_validation),
      "services" => Values.json_safe(manifest.services),
      "required_services" => Values.json_safe(manifest.required_services),
      "deployment" => Values.json_safe(manifest.deployment),
      "schedule" => Values.json_safe(manifest.schedule),
      "triggers" => Values.json_safe(manifest.triggers),
      "parameterized" => Values.json_safe(manifest.parameterized),
      "response_service" => Values.json_safe(manifest.response_service),
      "metadata" => Values.json_safe(manifest.metadata),
      "policies" => Values.json_safe(manifest.policies),
      "entrypoints" => manifest.entrypoints,
      "initial_inputs" => Values.json_safe(manifest.initial_inputs),
      "reload" => Values.json_safe(manifest.reload)
    })
    |> maybe_put("contract", manifest.contract)
    |> maybe_put("flow", flow_to_map(manifest))
    |> maybe_put("runtime", manifest.runtime)
  end

  defp node_to_map(node) do
    %{
      "node_id" => node.node_id,
      "agent_type" => node.agent_type,
      "type" => node.type,
      "role" => node.role,
      "config" => Values.json_safe(node.config),
      "resources" => Values.json_safe(node.resources),
      "constraints" => Values.json_safe(node.constraints),
      "placement_requirements" => Values.json_safe(Map.get(node, :placement_requirements, %{})),
      "tool_bindings" => Values.json_safe(node.tool_bindings),
      "retry_policy" => Values.json_safe(node.retry_policy),
      "spawn_policy" => Values.json_safe(node.spawn_policy),
      "policies" => Values.json_safe(Map.get(node, :policies, %{})),
      "services" => Values.json_safe(Map.get(node, :services, [])),
      "requires_services" => Values.json_safe(Map.get(node, :requires_services, []))
    }
  end

  defp edge_to_map(edge) do
    %{
      "edge_id" => edge.edge_id,
      "from_node" => edge.from_node,
      "to_node" => edge.to_node,
      "message_type" => edge.message_type,
      "routing_mode" => edge.routing_mode,
      "conditions" => Values.json_safe(edge.conditions)
    }
  end

  defp flow_to_map(%MirrorNeuron.Manifest{} = manifest) do
    flow =
      case manifest.flow do
        flow when is_map(flow) -> Values.json_safe(flow)
        _ -> %{}
      end

    flow
    |> Map.put("nodes", Enum.map(manifest.nodes, &node_to_map/1))
    |> Map.put("edges", Enum.map(manifest.edges, &edge_to_map/1))
  end

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, Values.json_safe(value))
end
