defmodule MirrorNeuron.Runtime.DynamicWorkflow.Operations do
  @moduledoc "Applies allowed step and edge changes to an isolated candidate graph."

  alias MirrorNeuron.Runtime.DynamicWorkflow.History
  alias MirrorNeuron.Runtime.DynamicWorkflow.Requests
  alias MirrorNeuron.Runtime.DynamicWorkflow.State

  @mutable_statuses ["pending", "ready", "blocked"]

  def apply_operations(state, region, request) do
    initial = {state, %{steps_added: [], steps_removed: [], edges_added: [], edges_removed: []}}

    Enum.reduce_while(request.operations, {:ok, initial}, fn operation,
                                                             {:ok, {candidate, delta}} ->
      case apply_operation(candidate, region, request, operation, delta) do
        {:ok, next, next_delta} -> {:cont, {:ok, {next, next_delta}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {candidate, delta}} ->
        dynamic_count = Enum.count(Map.values(candidate["steps"]), &State.active_dynamic_step?/1)

        if dynamic_count <= get_in(state, ["dynamic_limits", "max_active_steps"]) do
          {:ok, candidate, delta}
        else
          {:error, "active dynamic step limit exceeded"}
        end

      error ->
        error
    end
  end

  defp apply_operation(state, region, request, operation, delta) do
    case Requests.string_value(operation, "op") do
      "add_step" -> add_step(state, region, request, operation, delta)
      "remove_step" -> remove_step(state, region, operation, delta)
      "add_edge" -> add_edge(state, region, request, operation, delta)
      "remove_edge" -> remove_edge(state, region, operation, delta)
      other -> {:error, "unsupported patch operation #{inspect(other)}"}
    end
  end

  defp add_step(state, region, request, operation, delta) do
    id = Requests.string_value(operation, "id")
    template_id = Requests.string_value(operation, "template")
    allowed = Map.get(region, "templates", [])
    template = get_in(state, ["dynamic_templates", template_id])
    instance_input = Map.get(operation, "with", %{})

    cond do
      not Requests.valid_id?(id) ->
        {:error, "add_step id must be a valid identifier"}

      Map.has_key?(state["steps"], id) ->
        {:error, "step id #{id} already exists"}

      template_id not in allowed ->
        {:error, "template #{template_id} is not allowed in region #{region["id"]}"}

      not is_map(template) ->
        {:error, "unknown or unadmitted template #{template_id}"}

      not is_map(instance_input) ->
        {:error, "add_step with must be an object"}

      not is_nil(operation["label"]) and not is_binary(operation["label"]) ->
        {:error, "add_step label must be a string"}

      Requests.encoded_size(instance_input) >
          get_in(state, ["dynamic_limits", "max_instance_input_bytes"]) ->
        {:error, "dynamic step input exceeds the configured byte limit"}

      true ->
        step =
          template
          |> Map.merge(%{
            "id" => id,
            "label" => to_string(Map.get(operation, "label") || Map.get(template, "label") || id),
            "dynamic_instance" => true,
            "template_id" => template_id,
            "region_id" => region["id"],
            "patch_id" => request.patch_id,
            "instance_input" => instance_input
          })

        next =
          state
          |> put_in(["steps", id], step)
          |> Map.update("step_order", [id], &(&1 ++ [id]))

        {:ok, next, Map.update!(delta, :steps_added, &(&1 ++ [step]))}
    end
  end

  defp remove_step(state, region, operation, delta) do
    id = Requests.string_value(operation, "id")
    step = get_in(state, ["steps", id])
    incident? = Enum.any?(state["edges"], &(Map.get(&1, "from") == id or Map.get(&1, "to") == id))

    cond do
      not is_map(step) ->
        {:error, "unknown step #{id}"}

      not State.dynamic_step?(step) or step["region_id"] != region["id"] ->
        {:error, "only dynamic instances owned by the region may be removed"}

      Map.get(step, "status") not in @mutable_statuses or Map.get(step, "attempt_count", 0) > 0 ->
        {:error, "step #{id} has already started and is immutable"}

      incident? ->
        {:error, "remove incident edges before removing step #{id}"}

      true ->
        next =
          state
          |> update_in(["steps"], &Map.delete(&1, id))
          |> Map.update("step_order", [], &List.delete(&1, id))
          |> History.detach_patch_instance(step)

        {:ok, next, Map.update!(delta, :steps_removed, &(&1 ++ [id]))}
    end
  end

  defp add_edge(state, region, request, operation, delta) do
    id = Requests.string_value(operation, "id")
    from = Requests.string_value(operation, "from")
    to = Requests.string_value(operation, "to")
    edge_ids = MapSet.new(Enum.map(state["edges"], &Map.get(&1, "id")))

    cond do
      not Requests.valid_id?(id) ->
        {:error, "add_edge id must be a valid identifier"}

      MapSet.member?(edge_ids, id) ->
        {:error, "edge id #{id} already exists"}

      from == to ->
        {:error, "edge #{id} cannot be a self edge"}

      not Map.has_key?(state["steps"], from) or not Map.has_key?(state["steps"], to) ->
        {:error, "edge #{id} references an unknown step"}

      not endpoint_allowed?(state, region, from) or not endpoint_allowed?(state, region, to) ->
        {:error, "edge #{id} crosses the boundary of region #{region["id"]}"}

      not edge_endpoints_mutable?(state, region, from, to) ->
        {:error, "edge #{id} would mutate work that has already started"}

      true ->
        edge =
          operation
          |> Map.take(["accepts", "required"])
          |> Map.merge(%{
            "id" => id,
            "from" => from,
            "to" => to,
            "dynamic_region_id" => region["id"],
            "dynamic_added" => true,
            "patch_id" => request.patch_id
          })
          |> maybe_checkpoint_edge(region, request.base_revision + 1)

        {:ok, Map.update!(state, "edges", &(&1 ++ [edge])),
         Map.update!(delta, :edges_added, &(&1 ++ [edge]))}
    end
  end

  defp remove_edge(state, region, operation, delta) do
    id = Requests.string_value(operation, "id")
    edge = Enum.find(state["edges"], &(Map.get(&1, "id") == id))

    cond do
      not is_map(edge) ->
        {:error, "unknown edge #{id}"}

      edge["dynamic_region_id"] != region["id"] ->
        {:error, "edge #{id} is not mutable in region #{region["id"]}"}

      not endpoint_allowed?(state, region, edge["from"]) or
          not endpoint_allowed?(state, region, edge["to"]) ->
        {:error, "edge #{id} crosses the boundary of region #{region["id"]}"}

      edge["dynamic_added"] != true and edge["dynamic_mutable"] != true ->
        {:error, "edge #{id} is immutable"}

      not edge_endpoints_mutable?(state, region, edge["from"], edge["to"]) ->
        {:error, "edge #{id} belongs to work that has already started"}

      true ->
        next =
          Map.update!(state, "edges", &Enum.reject(&1, fn item -> Map.get(item, "id") == id end))

        {:ok, next, Map.update!(delta, :edges_removed, &(&1 ++ [id]))}
    end
  end

  defp endpoint_allowed?(state, region, id) do
    id in [region["controller"], region["exit"]] or
      case get_in(state, ["steps", id]) do
        %{"dynamic_instance" => true, "region_id" => region_id} -> region_id == region["id"]
        _ -> false
      end
  end

  defp edge_endpoints_mutable?(state, region, from, to) do
    source_mutable? =
      from == region["controller"] or never_started?(get_in(state, ["steps", from]))

    source_mutable? and never_started?(get_in(state, ["steps", to]))
  end

  defp never_started?(step) when is_map(step) do
    Map.get(step, "status") in @mutable_statuses and Map.get(step, "attempt_count", 0) == 0
  end

  defp never_started?(_step), do: false

  defp maybe_checkpoint_edge(
         edge,
         %{"strategy" => "checkpoint_fanout", "controller" => controller},
         revision
       ) do
    if edge["from"] == controller, do: Map.put(edge, "checkpoint_revision", revision), else: edge
  end

  defp maybe_checkpoint_edge(edge, _region, _revision), do: edge
end
