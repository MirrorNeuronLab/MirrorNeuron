defmodule MirrorNeuron.Manifest do
  defstruct [
    :manifest_version,
    :graph_id,
    :job_name,
    :metadata,
    :nodes,
    :edges,
    :policies,
    :entrypoints,
    :initial_inputs
  ]

  alias MirrorNeuron.AgentRegistry

  def load(%__MODULE__{} = manifest), do: {:ok, manifest}

  def load(path) when is_binary(path) do
    if File.exists?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, decoded} <- Jason.decode(raw) do
        normalize_and_validate(decoded)
      else
        {:error, error} when is_exception(error) -> {:error, Exception.message(error)}
        {:error, reason} -> {:error, "failed to load manifest: #{inspect(reason)}"}
      end
    else
      case Jason.decode(path) do
        {:ok, decoded} -> normalize_and_validate(decoded)
        {:error, error} -> {:error, Exception.message(error)}
      end
    end
  end

  def load(map) when is_map(map), do: normalize_and_validate(map)

  defp normalize_and_validate(raw) do
    manifest = %__MODULE__{
      manifest_version: Map.get(raw, "manifest_version"),
      graph_id: Map.get(raw, "graph_id"),
      job_name: Map.get(raw, "job_name") || Map.get(raw, "graph_id"),
      metadata: Map.get(raw, "metadata", %{}),
      nodes: Enum.map(Map.get(raw, "nodes", []), &normalize_node/1),
      edges: Enum.map(Map.get(raw, "edges", []), &normalize_edge/1),
      policies: Map.get(raw, "policies", %{}),
      entrypoints: normalize_entrypoints(Map.get(raw, "entrypoints"), Map.get(raw, "nodes", [])),
      initial_inputs: normalize_initial_inputs(Map.get(raw, "initial_inputs", %{}))
    }

    case validate(manifest) do
      :ok -> {:ok, manifest}
      {:error, errors} -> {:error, errors}
    end
  end

  def validate(%__MODULE__{} = manifest) do
    errors =
      []
      |> validate_required(manifest)
      |> validate_nodes(manifest)
      |> validate_edges(manifest)
      |> validate_entrypoints(manifest)
      |> validate_policies(manifest)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_required(errors, manifest) do
    errors
    |> maybe_add_error(is_nil(manifest.manifest_version), "manifest_version is required")
    |> maybe_add_error(is_nil(manifest.graph_id), "graph_id is required")
    |> maybe_add_error(manifest.nodes == [], "nodes must not be empty")
  end

  defp validate_nodes(errors, manifest) do
    node_ids = Enum.map(manifest.nodes, & &1.node_id)
    duplicates = node_ids -- Enum.uniq(node_ids)

    unsupported =
      manifest.nodes
      |> Enum.reject(&AgentRegistry.supported_type?(&1.agent_type))
      |> Enum.map(&"unsupported agent_type #{inspect(&1.agent_type)} for node #{&1.node_id}")

    empty_ids =
      manifest.nodes
      |> Enum.filter(&(is_nil(&1.node_id) or &1.node_id == ""))
      |> Enum.map(fn _ -> "node_id is required for every node" end)

    errors
    |> add_errors(Enum.map(Enum.uniq(duplicates), &"duplicate node_id #{&1}"))
    |> add_errors(unsupported)
    |> add_errors(empty_ids)
  end

  defp validate_edges(errors, manifest) do
    node_ids = MapSet.new(Enum.map(manifest.nodes, & &1.node_id))

    edge_errors =
      Enum.flat_map(manifest.edges, fn edge ->
        []
        |> maybe_collect_error(
          not MapSet.member?(node_ids, edge.from_node),
          "edge #{edge.edge_id || "unknown"} references missing from_node #{edge.from_node}"
        )
        |> maybe_collect_error(
          not MapSet.member?(node_ids, edge.to_node),
          "edge #{edge.edge_id || "unknown"} references missing to_node #{edge.to_node}"
        )
        |> maybe_collect_error(
          is_nil(edge.message_type) or edge.message_type == "",
          "edge #{edge.edge_id || "unknown"} must define message_type"
        )
      end)

    add_errors(errors, edge_errors)
  end

  defp validate_entrypoints(errors, manifest) do
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

    add_errors(errors, entrypoint_errors)
  end

  defp validate_policies(errors, manifest) do
    supported_recovery_modes = Application.get_env(:mirror_neuron, :supported_recovery_modes, [])
    recovery_mode = Map.get(manifest.policies, "recovery_mode", "local_restart")

    maybe_add_error(
      errors,
      recovery_mode not in supported_recovery_modes,
      "unsupported recovery_mode #{inspect(recovery_mode)}"
    )
  end

  defp normalize_node(raw) do
    %{
      node_id: Map.get(raw, "node_id"),
      agent_type: Map.get(raw, "agent_type"),
      role: Map.get(raw, "role"),
      config: Map.get(raw, "config", %{}),
      tool_bindings: Map.get(raw, "tool_bindings", []),
      retry_policy: Map.get(raw, "retry_policy", %{}),
      checkpoint_policy: Map.get(raw, "checkpoint_policy", %{}),
      spawn_policy: Map.get(raw, "spawn_policy", %{})
    }
  end

  defp normalize_edge(raw) do
    %{
      edge_id: Map.get(raw, "edge_id"),
      from_node: Map.get(raw, "from_node"),
      to_node: Map.get(raw, "to_node"),
      message_type: Map.get(raw, "message_type"),
      routing_mode: Map.get(raw, "routing_mode", "broadcast"),
      conditions: Map.get(raw, "conditions", %{})
    }
  end

  defp normalize_entrypoints(nil, raw_nodes) do
    raw_nodes
    |> Enum.filter(&(Map.get(&1, "role") in ["root", "root_coordinator"]))
    |> Enum.map(&Map.get(&1, "node_id"))
  end

  defp normalize_entrypoints(entrypoints, _raw_nodes) when is_list(entrypoints), do: entrypoints
  defp normalize_entrypoints(entrypoint, _raw_nodes) when is_binary(entrypoint), do: [entrypoint]
  defp normalize_entrypoints(_, _), do: []

  defp normalize_initial_inputs(inputs) when is_map(inputs) do
    Enum.into(inputs, %{}, fn {node_id, payload} ->
      values = if is_list(payload), do: payload, else: [payload]
      {node_id, values}
    end)
  end

  defp normalize_initial_inputs(inputs) when is_list(inputs) do
    %{"__entrypoints__" => inputs}
  end

  defp normalize_initial_inputs(_), do: %{}

  defp maybe_add_error(errors, true, message), do: [message | errors]
  defp maybe_add_error(errors, false, _message), do: errors

  defp maybe_collect_error(errors, true, message), do: [message | errors]
  defp maybe_collect_error(errors, false, _message), do: errors

  defp add_errors(errors, new_errors), do: Enum.reverse(new_errors) ++ errors
end
