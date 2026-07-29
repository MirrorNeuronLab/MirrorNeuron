defmodule MirrorNeuron.Runtime.DynamicWorkflowSpec do
  @moduledoc false

  @patch_hard_cap 100_000
  @active_step_hard_cap 1_000
  @operation_hard_cap 256
  @id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/

  def validation_errors(flow, node_ids) when is_map(flow) do
    mode = to_string(Map.get(flow, "mode") || "static_dag")
    dynamic = if is_map(Map.get(flow, "dynamic")), do: Map.get(flow, "dynamic"), else: %{}

    cond do
      mode not in ["static_dag", "dynamic_dag"] ->
        ["workflow mode must be static_dag or dynamic_dag"]

      mode == "static_dag" and Map.get(dynamic, "enabled") == true ->
        ["dynamic.enabled requires workflow mode dynamic_dag"]

      mode == "dynamic_dag" and Map.get(dynamic, "enabled") != true ->
        ["dynamic_dag workflows require dynamic.enabled true"]

      mode != "dynamic_dag" ->
        []

      true ->
        validate_dynamic_spec(flow, dynamic, MapSet.new(node_ids))
    end
  end

  def validation_errors(_flow, _node_ids), do: []

  defp validate_dynamic_spec(flow, dynamic, node_ids) do
    fixed_steps = List.wrap(Map.get(flow, "steps", [])) |> Enum.filter(&is_map/1)
    fixed_ids = fixed_steps |> Enum.map(&string_value(&1, "id")) |> MapSet.new()
    graph = if is_map(flow["graph"]), do: flow["graph"], else: %{}
    graph_edges = List.wrap(graph["edges"]) |> Enum.filter(&is_map/1)
    edges_by_id = Map.new(graph_edges, &{string_value(&1, "id"), &1})
    templates = normalize_templates(dynamic["templates"])
    template_ids = templates |> Enum.map(&string_value(&1, "id")) |> MapSet.new()
    regions = List.wrap(dynamic["regions"]) |> Enum.filter(&is_map/1)

    []
    |> maybe_error(
      dynamic["apply_at"] != "between_steps",
      "dynamic.apply_at must be between_steps"
    )
    |> maybe_error(templates == [], "dynamic.templates must declare at least one template")
    |> maybe_error(regions == [], "dynamic.regions must declare at least one region")
    |> Kernel.++(template_errors(templates, template_ids, fixed_ids, node_ids))
    |> Kernel.++(region_errors(regions, fixed_ids, template_ids, edges_by_id))
    |> Kernel.++(limit_errors(dynamic["limits"]))
  end

  defp normalize_templates(templates) when is_map(templates) do
    Enum.map(templates, fn {id, value} ->
      if is_map(value),
        do: Map.put_new(value, "id", to_string(id)),
        else: %{"id" => to_string(id)}
    end)
  end

  defp normalize_templates(templates) when is_list(templates),
    do: Enum.filter(templates, &is_map/1)

  defp normalize_templates(_templates), do: []

  defp template_errors(templates, template_ids, fixed_ids, node_ids) do
    duplicate_ids =
      templates
      |> Enum.map(&string_value(&1, "id"))
      |> then(&(&1 -- Enum.uniq(&1)))
      |> Enum.uniq()

    errors =
      Enum.flat_map(templates, fn template ->
        id = string_value(template, "id")
        run = string_value(template, "agent_id")
        run = if run == "", do: string_value(template, "run"), else: run

        []
        |> maybe_error(not valid_id?(id), "dynamic template id #{inspect(id)} is invalid")
        |> maybe_error(
          MapSet.member?(fixed_ids, id),
          "dynamic template id #{id} collides with a fixed step"
        )
        |> maybe_error(run == "", "dynamic template #{id} must declare run or agent_id")
        |> maybe_error(
          run != "" and not MapSet.member?(node_ids, run),
          "dynamic template #{id} worker #{run} is not pre-admitted"
        )
      end)

    errors ++
      Enum.map(duplicate_ids, &"duplicate dynamic template id #{&1}") ++
      if(MapSet.size(template_ids) == 0, do: ["dynamic.templates has no valid entries"], else: [])
  end

  defp region_errors(regions, fixed_ids, template_ids, edges_by_id) do
    ids = Enum.map(regions, &string_value(&1, "id"))
    duplicates = (ids -- Enum.uniq(ids)) |> Enum.uniq()

    errors =
      Enum.flat_map(regions, fn region ->
        id = string_value(region, "id")
        strategy = string_value(region, "strategy")
        controller = string_value(region, "controller")
        exit_id = string_value(region, "exit")
        templates = string_list(region["templates"])
        mutable_edges = string_list(region["mutable_edges"])

        []
        |> maybe_error(not valid_id?(id), "dynamic region id #{inspect(id)} is invalid")
        |> maybe_error(
          strategy not in ["replace_path", "checkpoint_fanout"],
          "dynamic region #{id} has unsupported strategy #{inspect(strategy)}"
        )
        |> maybe_error(
          not MapSet.member?(fixed_ids, controller),
          "dynamic region #{id} controller #{controller} is not a fixed step"
        )
        |> maybe_error(templates == [], "dynamic region #{id} must allow at least one template")
        |> maybe_error(
          Enum.any?(templates, &(not MapSet.member?(template_ids, &1))),
          "dynamic region #{id} references an unknown template"
        )
        |> maybe_error(
          strategy == "replace_path" and not MapSet.member?(fixed_ids, exit_id),
          "replace_path region #{id} exit #{exit_id} is not a fixed step"
        )
        |> maybe_error(
          strategy == "replace_path" and mutable_edges == [],
          "replace_path region #{id} must declare mutable_edges"
        )
        |> maybe_error(
          Enum.any?(mutable_edges, &(not Map.has_key?(edges_by_id, &1))),
          "dynamic region #{id} references an unknown mutable edge"
        )
        |> maybe_error(
          strategy == "replace_path" and
            Enum.any?(mutable_edges, fn edge_id ->
              case Map.get(edges_by_id, edge_id) do
                edge when is_map(edge) ->
                  string_value(edge, "from") != controller or
                    string_value(edge, "to") != exit_id

                _ ->
                  false
              end
            end),
          "replace_path region #{id} mutable edges must connect its controller to its exit"
        )
        |> maybe_error(
          strategy == "checkpoint_fanout" and mutable_edges != [],
          "checkpoint_fanout region #{id} cannot declare mutable_edges"
        )
      end)

    ownership_errors =
      regions
      |> Enum.flat_map(fn region ->
        Enum.map(string_list(region["mutable_edges"]), &{&1, string_value(region, "id")})
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {edge_id, owners} ->
        if length(Enum.uniq(owners)) > 1,
          do: ["mutable workflow edge #{edge_id} belongs to more than one dynamic region"],
          else: []
      end)

    errors ++ ownership_errors ++ Enum.map(duplicates, &"duplicate dynamic region id #{&1}")
  end

  defp limit_errors(limits) when is_map(limits) do
    [
      {"max_patches", @patch_hard_cap},
      {"max_active_steps", @active_step_hard_cap},
      {"max_operations_per_patch", @operation_hard_cap}
    ]
    |> Enum.flat_map(fn {key, cap} ->
      case Map.get(limits, key) do
        nil -> []
        value when is_integer(value) and value > 0 and value <= cap -> []
        _ -> ["dynamic limit #{key} must be a positive integer no greater than #{cap}"]
      end
    end)
    |> then(fn errors ->
      case Map.get(limits, "max_instance_input_bytes") do
        nil -> errors
        value when is_integer(value) and value > 0 -> errors
        _ -> errors ++ ["dynamic limit max_instance_input_bytes must be a positive integer"]
      end
    end)
  end

  defp limit_errors(nil), do: []
  defp limit_errors(_limits), do: ["dynamic.limits must be an object"]

  defp valid_id?(value), do: is_binary(value) and Regex.match?(@id_pattern, value)
  defp string_value(map, key) when is_map(map), do: to_string(Map.get(map, key) || "")
  defp string_value(_map, _key), do: ""

  defp string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_error(errors, true, message), do: errors ++ [message]
  defp maybe_error(errors, _condition, _message), do: errors
end
