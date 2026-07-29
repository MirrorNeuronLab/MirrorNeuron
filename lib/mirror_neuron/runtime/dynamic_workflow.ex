defmodule MirrorNeuron.Runtime.DynamicWorkflow do
  @moduledoc false

  @batch_patch_default 64
  @service_patch_default 10_000
  @active_step_default 128
  @operation_default 64
  @instance_input_default 32 * 1024
  @patch_hard_cap 100_000
  @active_step_hard_cap 1_000
  @operation_hard_cap 256
  @history_default 256
  @mutable_statuses ["pending", "ready", "blocked"]
  @terminal_statuses ["completed", "partial", "skipped", "failed"]
  @id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/

  def initialize(state, flow, templates) when is_map(state) and is_map(flow) do
    dynamic = if is_map(Map.get(flow, "dynamic")), do: Map.get(flow, "dynamic"), else: %{}
    mode = to_string(Map.get(flow, "mode") || "static_dag")
    enabled? = mode == "dynamic_dag" and Map.get(dynamic, "enabled") == true

    if enabled? do
      regions =
        dynamic
        |> Map.get("regions", [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Map.new(fn region ->
          {to_string(Map.get(region, "id") || ""), normalize_region(region)}
        end)

      limits = normalize_limits(dynamic, regions)
      mutable_owners = mutable_edge_owners(regions)

      edges =
        Enum.map(Map.get(state, "edges", []), fn edge ->
          case Map.get(mutable_owners, Map.get(edge, "id")) do
            nil ->
              edge

            region_id ->
              Map.merge(edge, %{"dynamic_region_id" => region_id, "dynamic_mutable" => true})
          end
        end)

      state
      |> Map.put("mode", mode)
      |> Map.put("dynamic_enabled", true)
      |> Map.put("graph_revision", 0)
      |> Map.put("dynamic_limits", limits)
      |> Map.put("dynamic_templates", templates)
      |> Map.put("dynamic_regions", regions)
      |> Map.put("applied_patches", %{})
      |> Map.put("patch_order", [])
      |> Map.put("dynamic_patch_instances", %{})
      |> Map.put("dynamic_history", [])
      |> Map.put("edges", edges)
    else
      state
      |> Map.put("mode", mode)
      |> Map.put("dynamic_enabled", false)
      |> Map.put_new("graph_revision", 0)
    end
  end

  def initialize(state, _flow, _templates), do: state

  def enabled?(%{"dynamic_enabled" => true, "mode" => "dynamic_dag"}), do: true
  def enabled?(_state), do: false

  def graph_revision(state), do: Map.get(state, "graph_revision", 0)

  def dynamic_step?(step) when is_map(step), do: Map.get(step, "dynamic_instance") == true
  def dynamic_step?(_step), do: false

  def managed_target?(state, step) when is_map(step) do
    dynamic_step?(step) or
      Enum.any?(Map.get(state, "edges", []), fn edge ->
        Map.get(edge, "to") == Map.get(step, "id") and
          (Map.get(edge, "dynamic_mutable") == true or
             is_binary(Map.get(edge, "dynamic_region_id")))
      end)
  end

  def dependency_checkpointed?(state, edge) when is_map(edge) do
    revision = Map.get(edge, "checkpoint_revision")
    is_integer(revision) and revision > 0 and revision <= graph_revision(state)
  end

  def apply_patch(state, controller_step, payload, now)
      when is_map(state) and is_map(controller_step) and is_map(payload) do
    with :ok <- ensure_dynamic_enabled(state),
         {:ok, request} <- normalize_patch_request(payload),
         {:ok, duplicate} <- deduplicate(state, request),
         :continue <- duplicate,
         {:ok, region} <- fetch_region(state, request.region_id),
         :ok <- authorize_controller(region, controller_step),
         :ok <- validate_revision(state, request.base_revision),
         :ok <- validate_patch_limits(state, request),
         {:ok, candidate, delta} <- apply_operations(state, region, request),
         :ok <- validate_candidate(candidate, region) do
      revision = graph_revision(state) + 1
      digest = patch_digest(request.raw)

      candidate =
        candidate
        |> Map.put("graph_revision", revision)
        |> put_in(["applied_patches", request.patch_id], %{
          "digest" => digest,
          "revision" => revision,
          "region_id" => request.region_id
        })
        |> Map.update("patch_order", [request.patch_id], &(&1 ++ [request.patch_id]))
        |> record_patch_instances(request, region, delta, revision, now)
        |> Map.put("updated_at", now)

      event = %{
        type: :workflow_graph_patch_applied,
        step: controller_step["id"],
        step_id: controller_step["id"],
        agent_id: primary_agent_id(controller_step),
        patch_id: request.patch_id,
        region_id: request.region_id,
        graph_revision: revision,
        strategy: region["strategy"],
        topology_delta: public_delta(delta),
        timestamp: now
      }

      {:ok, candidate, event, region["strategy"]}
    else
      {:duplicate, record, request} ->
        event = %{
          type: :workflow_graph_patch_replayed,
          step: controller_step["id"],
          step_id: controller_step["id"],
          agent_id: primary_agent_id(controller_step),
          patch_id: request.patch_id,
          region_id: request.region_id,
          graph_revision: record["revision"],
          timestamp: now
        }

        strategy =
          state
          |> get_in(["dynamic_regions", request.region_id, "strategy"])

        {:duplicate, state, event, strategy}

      {:error, reason} ->
        event =
          rejection_event(controller_step, payload, reason, now)
          |> Map.put(:graph_revision, graph_revision(state))

        {:error, state, event}

      other ->
        event =
          rejection_event(controller_step, payload, inspect(other), now)
          |> Map.put(:graph_revision, graph_revision(state))

        {:error, state, event}
    end
  end

  def apply_patch(state, controller_step, payload, now) do
    {:error, state,
     rejection_event(controller_step || %{}, payload || %{}, "invalid patch payload", now)}
  end

  def checkpoint(state, controller_step, payload, now)
      when is_map(state) and is_map(controller_step) and is_map(payload) do
    with :ok <- ensure_dynamic_enabled(state),
         {:ok, region} <- checkpoint_region(state, controller_step, payload),
         :ok <- authorize_controller(region, controller_step) do
      event = %{
        type: :workflow_controller_checkpointed,
        step: controller_step["id"],
        step_id: controller_step["id"],
        agent_id: primary_agent_id(controller_step),
        region_id: region["id"],
        graph_revision: graph_revision(state),
        timestamp: now
      }

      {:ok, Map.put(state, "updated_at", now), event}
    else
      {:error, reason} ->
        event =
          rejection_event(controller_step, payload, reason, now)
          |> Map.put(:type, :workflow_controller_checkpoint_rejected)
          |> Map.put(:graph_revision, graph_revision(state))

        {:error, state, event}
    end
  end

  def checkpoint(state, controller_step, payload, now) do
    {:error, state,
     rejection_event(
       controller_step || %{},
       payload || %{},
       "invalid controller checkpoint",
       now
     )}
  end

  def retire_completed_service_patches(state, now) do
    patches = Map.get(state, "dynamic_patch_instances", %{})

    Enum.reduce(patches, {state, []}, fn {patch_id, record}, {acc, events} ->
      if record["strategy"] == "checkpoint_fanout" and not record["retired"] and
           all_terminal?(acc, record["step_ids"]) do
        {next, event} = retire_patch(acc, patch_id, record, now)
        {next, events ++ [event]}
      else
        {acc, events}
      end
    end)
  end

  def public_state(state) when is_map(state) do
    state
    |> Map.drop(["dynamic_templates", "applied_patches", "dynamic_patch_instances"])
    |> Map.update("steps", %{}, fn steps ->
      Map.new(steps, fn {id, step} -> {id, Map.drop(step, ["instance_input"])} end)
    end)
  end

  defp normalize_patch_request(payload) do
    patch_id = string_value(payload, "patch_id")
    region_id = string_value(payload, "region_id")
    base_revision = Map.get(payload, "base_revision")
    operations = Map.get(payload, "operations")

    cond do
      not valid_id?(patch_id) ->
        {:error, "patch_id is required and must be a valid identifier"}

      not valid_id?(region_id) ->
        {:error, "region_id is required and must be a valid identifier"}

      not is_integer(base_revision) or base_revision < 0 ->
        {:error, "base_revision must be a non-negative integer"}

      not is_list(operations) or operations == [] ->
        {:error, "operations must be a non-empty list"}

      not Enum.all?(operations, &is_map/1) ->
        {:error, "every patch operation must be an object"}

      true ->
        raw = %{
          "patch_id" => patch_id,
          "region_id" => region_id,
          "base_revision" => base_revision,
          "operations" => operations
        }

        {:ok,
         %{
           patch_id: patch_id,
           region_id: region_id,
           base_revision: base_revision,
           operations: operations,
           raw: raw
         }}
    end
  end

  defp deduplicate(state, request) do
    case get_in(state, ["applied_patches", request.patch_id]) do
      nil ->
        {:ok, :continue}

      %{"digest" => digest} = record ->
        if digest == patch_digest(request.raw) do
          {:ok, {:duplicate, record, request}}
        else
          {:error, "patch_id #{request.patch_id} was already used with different content"}
        end
    end
  end

  defp fetch_region(state, region_id) do
    case get_in(state, ["dynamic_regions", region_id]) do
      region when is_map(region) -> {:ok, region}
      _ -> {:error, "unknown dynamic region #{region_id}"}
    end
  end

  defp checkpoint_region(state, controller_step, payload) do
    requested = string_value(payload, "region_id")

    regions =
      state
      |> Map.get("dynamic_regions", %{})
      |> Map.values()
      |> Enum.filter(
        &(Map.get(&1, "strategy") == "checkpoint_fanout" and
            Map.get(&1, "controller") == controller_step["id"])
      )

    region =
      if requested == "",
        do: List.first(regions),
        else: Enum.find(regions, &(Map.get(&1, "id") == requested))

    if region,
      do: {:ok, region},
      else: {:error, "controller does not own a checkpoint_fanout region"}
  end

  defp authorize_controller(region, controller_step) do
    current_attempt = Map.get(controller_step, "current_attempt")

    if region["controller"] == controller_step["id"] and
         Map.get(controller_step, "status") in ["running", "queued"] and
         is_map(current_attempt) and
         Map.get(current_attempt, "agent_id") in Map.get(controller_step, "agent_ids", []) do
      :ok
    else
      {:error, "patch requester is not the region's active controller"}
    end
  end

  defp validate_revision(state, revision) do
    if revision == graph_revision(state),
      do: :ok,
      else:
        {:error, "stale base_revision #{revision}; current revision is #{graph_revision(state)}"}
  end

  defp validate_patch_limits(state, request) do
    limits = Map.get(state, "dynamic_limits", %{})
    patch_count = length(Map.get(state, "patch_order", []))

    dynamic_count =
      Enum.count(Map.values(Map.get(state, "steps", %{})), &active_dynamic_step?/1)

    cond do
      patch_count >= limits["max_patches"] ->
        {:error, "dynamic patch limit exceeded"}

      length(request.operations) > limits["max_operations_per_patch"] ->
        {:error, "patch operation limit exceeded"}

      dynamic_count > limits["max_active_steps"] ->
        {:error, "active dynamic step limit exceeded"}

      true ->
        :ok
    end
  end

  defp apply_operations(state, region, request) do
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
        dynamic_count = Enum.count(Map.values(candidate["steps"]), &active_dynamic_step?/1)

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
    case string_value(operation, "op") do
      "add_step" -> add_step(state, region, request, operation, delta)
      "remove_step" -> remove_step(state, region, operation, delta)
      "add_edge" -> add_edge(state, region, request, operation, delta)
      "remove_edge" -> remove_edge(state, region, operation, delta)
      other -> {:error, "unsupported patch operation #{inspect(other)}"}
    end
  end

  defp add_step(state, region, request, operation, delta) do
    id = string_value(operation, "id")
    template_id = string_value(operation, "template")
    allowed = Map.get(region, "templates", [])
    template = get_in(state, ["dynamic_templates", template_id])
    instance_input = Map.get(operation, "with", %{})

    cond do
      not valid_id?(id) ->
        {:error, "add_step id must be a valid identifier"}

      Map.has_key?(state["steps"], id) ->
        {:error, "step id #{id} already exists"}

      template_id not in allowed ->
        {:error, "template #{template_id} is not allowed in region #{region["id"]}"}

      not is_map(template) ->
        {:error, "unknown or unadmitted template #{template_id}"}

      not is_map(instance_input) ->
        {:error, "add_step with must be an object"}

      encoded_size(instance_input) > get_in(state, ["dynamic_limits", "max_instance_input_bytes"]) ->
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
    id = string_value(operation, "id")
    step = get_in(state, ["steps", id])
    incident? = Enum.any?(state["edges"], &(Map.get(&1, "from") == id or Map.get(&1, "to") == id))

    cond do
      not is_map(step) ->
        {:error, "unknown step #{id}"}

      not dynamic_step?(step) or step["region_id"] != region["id"] ->
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
          |> detach_patch_instance(step)

        {:ok, next, Map.update!(delta, :steps_removed, &(&1 ++ [id]))}
    end
  end

  defp add_edge(state, region, request, operation, delta) do
    id = string_value(operation, "id")
    from = string_value(operation, "from")
    to = string_value(operation, "to")
    edge_ids = MapSet.new(Enum.map(state["edges"], &Map.get(&1, "id")))

    cond do
      not valid_id?(id) ->
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
    id = string_value(operation, "id")
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

  defp validate_candidate(state, region) do
    ids = Map.keys(state["steps"])
    edges = state["edges"]

    cond do
      Enum.any?(
        edges,
        &(not Map.has_key?(state["steps"], &1["from"]) or
              not Map.has_key?(state["steps"], &1["to"]))
      ) ->
        {:error, "patch leaves a dangling workflow edge"}

      cyclic?(ids, edges) ->
        {:error, "patch would make the active workflow graph cyclic"}

      region["strategy"] == "replace_path" ->
        validate_replace_path(state, region)

      region["strategy"] == "checkpoint_fanout" ->
        validate_checkpoint_fanout(state, region)

      true ->
        {:error, "unsupported dynamic region strategy #{inspect(region["strategy"])}"}
    end
  end

  defp validate_replace_path(state, region) do
    controller = region["controller"]
    exit_id = region["exit"]
    dynamic_ids = region_dynamic_ids(state, region["id"])

    cond do
      not reachable?(state, controller, exit_id) ->
        {:error, "replace_path patch must keep the fixed exit reachable from its controller"}

      Enum.any?(dynamic_ids, fn id ->
        not reachable?(state, controller, id) or not reachable?(state, id, exit_id)
      end) ->
        {:error, "every replace_path instance must remain on a controller-to-exit path"}

      true ->
        :ok
    end
  end

  defp validate_checkpoint_fanout(state, region) do
    if Enum.all?(
         region_dynamic_ids(state, region["id"]),
         &reachable?(state, region["controller"], &1)
       ),
       do: :ok,
       else: {:error, "every checkpoint_fanout instance must be controller-reachable"}
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

  defp record_patch_instances(state, request, region, delta, revision, now) do
    step_ids = Enum.map(delta.steps_added, & &1["id"])
    edge_ids = Enum.map(delta.edges_added, & &1["id"])

    if step_ids == [] do
      state
    else
      put_in(state, ["dynamic_patch_instances", request.patch_id], %{
        "patch_id" => request.patch_id,
        "region_id" => region["id"],
        "strategy" => region["strategy"],
        "revision" => revision,
        "step_ids" => step_ids,
        "edge_ids" => edge_ids,
        "retired" => false,
        "created_at" => now
      })
    end
  end

  defp detach_patch_instance(state, step) do
    patch_id = step["patch_id"]

    case get_in(state, ["dynamic_patch_instances", patch_id]) do
      record when is_map(record) ->
        remaining = List.delete(Map.get(record, "step_ids", []), step["id"])

        if remaining == [] do
          update_in(state, ["dynamic_patch_instances"], &Map.delete(&1, patch_id))
        else
          put_in(state, ["dynamic_patch_instances", patch_id, "step_ids"], remaining)
        end

      _ ->
        state
    end
  end

  defp all_terminal?(state, step_ids) do
    step_ids != [] and
      Enum.all?(step_ids, fn id ->
        get_in(state, ["steps", id, "status"]) in @terminal_statuses
      end)
  end

  defp retire_patch(state, patch_id, record, now) do
    step_ids = record["step_ids"]
    edge_ids = MapSet.new(record["edge_ids"])

    summary = %{
      "patch_id" => patch_id,
      "region_id" => record["region_id"],
      "revision" => record["revision"],
      "retired_at" => now,
      "steps" =>
        Enum.map(step_ids, fn id ->
          step = get_in(state, ["steps", id]) || %{}
          %{"id" => id, "template_id" => step["template_id"], "status" => step["status"]}
        end)
    }

    history_limit = get_in(state, ["dynamic_limits", "max_history"]) || @history_default
    history = (Map.get(state, "dynamic_history", []) ++ [summary]) |> Enum.take(-history_limit)

    next =
      state
      |> update_in(["steps"], &Map.drop(&1, step_ids))
      |> Map.update("step_order", [], &Enum.reject(&1, fn id -> id in step_ids end))
      |> Map.update("edges", [], fn edges ->
        Enum.reject(edges, fn edge ->
          MapSet.member?(edge_ids, edge["id"]) or edge["from"] in step_ids or
            edge["to"] in step_ids
        end)
      end)
      |> update_in(["dynamic_patch_instances"], &Map.delete(&1, patch_id))
      |> Map.put("dynamic_history", history)
      |> Map.put("updated_at", now)

    event = %{
      type: :workflow_dynamic_steps_retired,
      patch_id: patch_id,
      region_id: record["region_id"],
      graph_revision: graph_revision(state),
      step_ids: step_ids,
      timestamp: now
    }

    {next, event}
  end

  defp public_delta(delta) do
    %{
      "steps_added" =>
        Enum.map(delta.steps_added, fn step ->
          Map.take(step, ["id", "label", "run", "agent_ids", "template_id", "region_id"])
        end),
      "steps_removed" => delta.steps_removed,
      "edges_added" =>
        Enum.map(
          delta.edges_added,
          &Map.take(&1, ["id", "from", "to", "accepts", "dynamic_region_id"])
        ),
      "edges_removed" => delta.edges_removed
    }
  end

  defp rejection_event(step, payload, reason, now) do
    %{
      type: :workflow_graph_patch_rejected,
      step: step["id"],
      step_id: step["id"],
      agent_id: primary_agent_id(step),
      patch_id: string_value(payload, "patch_id"),
      region_id: string_value(payload, "region_id"),
      graph_revision: Map.get(payload, "base_revision"),
      reason: reason,
      timestamp: now
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_region(region) do
    %{
      "id" => string_value(region, "id"),
      "strategy" => string_value(region, "strategy"),
      "controller" => string_value(region, "controller"),
      "exit" => string_value(region, "exit"),
      "templates" => string_list(Map.get(region, "templates")),
      "mutable_edges" => string_list(Map.get(region, "mutable_edges"))
    }
  end

  defp normalize_limits(dynamic, regions) do
    configured = if is_map(dynamic["limits"]), do: dynamic["limits"], else: %{}
    service? = Enum.any?(Map.values(regions), &(&1["strategy"] == "checkpoint_fanout"))
    default_patches = if service?, do: @service_patch_default, else: @batch_patch_default

    %{
      "max_patches" =>
        bounded_positive(configured["max_patches"], default_patches, @patch_hard_cap),
      "max_active_steps" =>
        bounded_positive(
          configured["max_active_steps"],
          @active_step_default,
          @active_step_hard_cap
        ),
      "max_operations_per_patch" =>
        bounded_positive(
          configured["max_operations_per_patch"],
          @operation_default,
          @operation_hard_cap
        ),
      "max_instance_input_bytes" =>
        positive_or_default(configured["max_instance_input_bytes"], @instance_input_default),
      "max_history" => bounded_positive(configured["max_history"], @history_default, 10_000)
    }
  end

  defp mutable_edge_owners(regions) do
    Enum.reduce(regions, %{}, fn {region_id, region}, owners ->
      Enum.reduce(region["mutable_edges"], owners, &Map.put(&2, &1, region_id))
    end)
  end

  defp region_dynamic_ids(state, region_id) do
    state["steps"]
    |> Enum.filter(fn {_id, step} -> dynamic_step?(step) and step["region_id"] == region_id end)
    |> Enum.map(&elem(&1, 0))
  end

  defp reachable?(state, source, target),
    do: reachable?(state["edges"], MapSet.new(), [source], target)

  defp reachable?(_edges, _seen, [], _target), do: false
  defp reachable?(_edges, _seen, [target | _], target), do: true

  defp reachable?(edges, seen, [current | rest], target) do
    if MapSet.member?(seen, current) do
      reachable?(edges, seen, rest, target)
    else
      next = for edge <- edges, edge["from"] == current, do: edge["to"]
      reachable?(edges, MapSet.put(seen, current), rest ++ next, target)
    end
  end

  defp cyclic?(ids, edges) do
    parents = Map.new(ids, &{&1, MapSet.new()})

    parents =
      Enum.reduce(edges, parents, fn edge, acc ->
        if Map.has_key?(acc, edge["from"]) and Map.has_key?(acc, edge["to"]) do
          Map.update!(acc, edge["to"], &MapSet.put(&1, edge["from"]))
        else
          acc
        end
      end)

    remove_acyclic(parents, MapSet.new()) != map_size(parents)
  end

  defp remove_acyclic(parents, removed) do
    ready =
      Enum.filter(parents, fn {id, dependencies} ->
        not MapSet.member?(removed, id) and MapSet.subset?(dependencies, removed)
      end)

    if ready == [] do
      MapSet.size(removed)
    else
      next = Enum.reduce(ready, removed, fn {id, _}, acc -> MapSet.put(acc, id) end)
      remove_acyclic(parents, next)
    end
  end

  defp ensure_dynamic_enabled(state),
    do: if(enabled?(state), do: :ok, else: {:error, "dynamic workflow patches are not enabled"})

  defp patch_digest(value) do
    value
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      _ -> @instance_input_default + 1
    end
  end

  defp valid_id?(value), do: is_binary(value) and Regex.match?(@id_pattern, value)

  defp active_dynamic_step?(step),
    do: dynamic_step?(step) and step["status"] not in @terminal_statuses

  defp string_value(map, key) when is_map(map), do: to_string(Map.get(map, key) || "")
  defp string_value(_map, _key), do: ""

  defp string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp bounded_positive(value, _default, cap) when is_integer(value) and value > 0,
    do: min(value, cap)

  defp bounded_positive(_value, default, _cap), do: default

  defp positive_or_default(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_or_default(_value, default), do: default

  defp primary_agent_id(%{"agent_ids" => [agent_id | _]}), do: agent_id
  defp primary_agent_id(_step), do: nil
end
