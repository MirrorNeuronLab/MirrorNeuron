defmodule MirrorNeuron.Manifest.Topology do
  @moduledoc "Normalizes physical nodes and edges and validates their routing references."

  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.AgentTemplates
  alias MirrorNeuron.Runtime.RouteCondition
  alias MirrorNeuron.ServiceSpec
  alias MirrorNeuron.Manifest.Values

  def validate_nodes(errors, manifest) do
    node_ids = Enum.map(manifest.nodes, & &1.node_id)
    duplicates = node_ids -- Enum.uniq(node_ids)

    unsupported =
      manifest.nodes
      |> Enum.reject(&AgentRegistry.supported_type?(&1.agent_type))
      |> Enum.map(&"unsupported agent_type #{inspect(&1.agent_type)} for node #{&1.node_id}")

    unsupported_templates =
      manifest.nodes
      |> Enum.reject(&AgentTemplates.supported_type?(&1.type))
      |> Enum.map(&"unsupported template type #{inspect(&1.type)} for node #{&1.node_id}")

    incompatible_templates =
      manifest.nodes
      |> Enum.reject(&AgentTemplates.supported_for_agent_type?(&1.type, &1.agent_type))
      |> Enum.map(
        &"template type #{inspect(&1.type)} is not supported for agent_type #{inspect(&1.agent_type)} on node #{&1.node_id}"
      )

    empty_ids =
      manifest.nodes
      |> Enum.filter(&(is_nil(&1.node_id) or &1.node_id == ""))
      |> Enum.map(fn _ -> "node_id is required for every node" end)

    errors
    |> Values.add_errors(Enum.map(Enum.uniq(duplicates), &"duplicate node_id #{&1}"))
    |> Values.add_errors(unsupported)
    |> Values.add_errors(unsupported_templates)
    |> Values.add_errors(incompatible_templates)
    |> Values.add_errors(empty_ids)
  end

  def validate_edges(errors, manifest) do
    node_ids = MapSet.new(Enum.map(manifest.nodes, & &1.node_id))

    edge_errors =
      Enum.flat_map(manifest.edges, fn edge ->
        []
        |> Values.maybe_collect_error(
          not MapSet.member?(node_ids, edge.from_node),
          "edge #{edge.edge_id || "unknown"} references missing from_node #{edge.from_node}"
        )
        |> Values.maybe_collect_error(
          not MapSet.member?(node_ids, edge.to_node),
          "edge #{edge.edge_id || "unknown"} references missing to_node #{edge.to_node}"
        )
        |> Values.maybe_collect_error(
          is_nil(edge.message_type) or edge.message_type == "",
          "edge #{edge.edge_id || "unknown"} must define message_type"
        )
        |> Values.maybe_collect_error(
          edge.routing_mode not in RouteCondition.supported_routing_modes(),
          "edge #{edge.edge_id || "unknown"} has unsupported routing_mode #{inspect(edge.routing_mode)}"
        )
        |> add_condition_error(edge)
      end)

    Values.add_errors(errors, edge_errors)
  end

  defp add_condition_error(errors, edge) do
    case RouteCondition.validate(edge.conditions) do
      :ok ->
        errors

      {:error, reason} ->
        ["edge #{edge.edge_id || "unknown"} has invalid conditions: #{reason}" | errors]
    end
  end

  def validate_entrypoints(errors, manifest) do
    node_ids = MapSet.new(Enum.map(manifest.nodes, & &1.node_id))

    entrypoint_errors =
      manifest.entrypoints
      |> Enum.reject(&MapSet.member?(node_ids, &1))
      |> Enum.map(&"entrypoint #{&1} does not reference a known node")

    maybe_add_default_entrypoint_error(errors, manifest, entrypoint_errors)
  end

  defp maybe_add_default_entrypoint_error(errors, manifest, entrypoint_errors) do
    root_roles =
      manifest.nodes
      |> Enum.filter(&(&1.role in ["root", "root_coordinator"]))

    errors =
      if manifest.entrypoints == [] and root_roles == [] do
        [
          "manifest must define at least one entrypoint or one node with role root/root_coordinator"
          | errors
        ]
      else
        errors
      end

    Values.add_errors(errors, entrypoint_errors)
  end

  def normalize_node(raw) do
    %{
      node_id: Map.get(raw, "node_id"),
      agent_type: Map.get(raw, "agent_type"),
      type: AgentTemplates.canonical_type(Map.get(raw, "type")),
      role: Map.get(raw, "role"),
      config: Map.get(raw, "config", %{}),
      resources: Map.get(raw, "resources", %{}),
      constraints: Map.get(raw, "constraints", []),
      placement_requirements: Map.get(raw, "placement_requirements", %{}),
      tool_bindings: Map.get(raw, "tool_bindings", []),
      retry_policy: Map.get(raw, "retry_policy", %{}),
      spawn_policy: Map.get(raw, "spawn_policy", %{}),
      policies: Map.get(raw, "policies", %{}),
      services: ServiceSpec.normalize_services(Map.get(raw, "services", [])),
      requires_services:
        ServiceSpec.normalize_requires_services(Map.get(raw, "requires_services", []))
    }
  end

  def normalize_edge(raw) do
    %{
      edge_id: Map.get(raw, "edge_id"),
      from_node: Map.get(raw, "from_node"),
      to_node: Map.get(raw, "to_node"),
      message_type: Map.get(raw, "message_type"),
      routing_mode: Map.get(raw, "routing_mode", "broadcast"),
      conditions: Map.get(raw, "conditions", %{})
    }
  end
end
