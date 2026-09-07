defmodule MirrorNeuron.Runtime.ChildWorkflow do
  @moduledoc "Bounded child DAG rounds, scheduled and persisted by the workflow ledger."

  alias MirrorNeuron.Artifacts.StagedArtifact

  @terminal ["completed", "partial", "skipped"]
  @id ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/

  def initialize(state, flow, templates) do
    state
    |> Map.put("child_definitions", Map.get(flow, "child_workflows", %{}))
    |> Map.put("child_templates", templates)
    |> Map.put("child_workflows", %{})
  end

  def validation_errors(flow, node_ids) do
    children = Map.get(flow, "child_workflows", %{})
    fixed = Enum.map(Map.get(flow, "steps", []), & &1["id"])

    if is_map(children) do
      Enum.flat_map(children, fn {parent, spec} ->
        templates = if is_map(spec), do: Map.get(spec, "templates", %{}), else: %{}

        valid =
          is_map(spec) and is_map(templates) and parent in fixed and
            Map.has_key?(templates, spec["planner"]) and
            is_integer(spec["max_rounds"]) and spec["max_rounds"] in 1..20 and
            is_integer(spec["max_steps_per_round"]) and spec["max_steps_per_round"] in 1..128 and
            valid_mapping?(spec["inputs"]) and valid_mapping?(spec["outputs"]) and
            not Map.has_key?(spec, "child_workflows") and
            Enum.all?(templates, fn {id, template} ->
              is_map(template) and Regex.match?(@id, id) and id not in fixed and
                (template["agent_id"] || template["run"]) in node_ids and
                not Map.has_key?(template, "child_workflows")
            end)

        if valid, do: [], else: ["Invalid child workflow declaration for #{parent}"]
      end)
    else
      ["child_workflows must be an object"]
    end
  end

  def public_snapshot(state) do
    children =
      Map.new(Map.get(state, "child_workflows", %{}), fn {parent, child} ->
        {parent, Map.take(child, ["parent_step_id", "phase", "round", "revision"])}
      end)

    state
    |> Map.drop(["child_definitions", "child_templates"])
    |> Map.put("child_workflows", children)
  end

  defp valid_mapping?(mapping) when is_map(mapping) do
    Enum.all?(mapping, fn {key, path} ->
      is_binary(key) and is_list(path) and Enum.all?(path, &is_binary/1)
    end)
  end

  defp valid_mapping?(_), do: false

  def parent?(state, step), do: Map.has_key?(state["child_definitions"] || %{}, step["id"])
  def child?(step), do: is_binary(step["parent_step_id"])

  def managed_target?(state, step) do
    child?(step) or
      Enum.any?(state["edges"], fn edge ->
        edge["to"] == step["id"] and Map.has_key?(state["child_definitions"] || %{}, edge["from"])
      end)
  end

  def start(state, parent, payload, now) do
    id = parent["id"]

    if Map.has_key?(state["child_workflows"], id) do
      {state, []}
    else
      spec = state["child_definitions"][id]

      child = %{
        "parent_step_id" => id,
        "phase" => "planning",
        "round" => 0,
        "revision" => 0,
        "plans" => [],
        "results" => [],
        "active" => [],
        "input" => map_fields(payload, spec["inputs"]),
        "boundary_output" => payload
      }

      state = put_in(state, ["child_workflows", id], child)
      # The generated sink has handed off completion; the parent timeout remains authoritative.
      state = put_in(state, ["steps", id, "heartbeat_deadline_at"], nil)
      state = add_planner(state, id, now)
      {state, [event(state, id, :workflow_child_started)]}
    end
  rescue
    error in [KeyError, BadMapError, ArgumentError] ->
      failed =
        Map.merge(parent, %{"status" => "failed", "terminal_reason" => Exception.message(error)})

      {put_in(state, ["steps", parent["id"]], failed),
       [
         %{
           type: :workflow_child_failed,
           parent_step_id: parent["id"],
           reason: Exception.message(error)
         }
       ]}
  end

  def completed(state, step, payload, now) do
    if child?(step) do
      parent = step["parent_step_id"]
      child = state["child_workflows"][parent]

      try do
        cond do
          step["child_phase"] == "planning" ->
            commit(state, parent, plan_payload(payload), now)

          child["phase"] == "executing" and
              Enum.all?(child["active"], &(state["steps"][&1]["status"] in @terminal)) ->
            results =
              Enum.map(child["active"], fn id ->
                %{"step_id" => id, "output" => completed_output(state["steps"][id])}
              end)

            child = child |> Map.put("phase", "planning") |> Map.put("results", results)
            state = put_in(state, ["child_workflows", parent], child) |> add_planner(parent, now)
            {state, [event(state, parent, :workflow_child_round_completed)], nil}

          true ->
            {state, [], nil}
        end
      rescue
        error in [ArgumentError, KeyError, BadMapError] ->
          reason = Exception.message(error)
          state = put_in(state, ["child_workflows", parent, "phase"], "failed")

          {state, [Map.put(event(state, parent, :workflow_child_failed), :reason, reason)],
           {:failed, parent, reason}}
      end
    else
      {state, [], nil}
    end
  end

  defp commit(state, parent, plan, now) do
    unless is_map(plan), do: raise(ArgumentError, "Child plan must be an object")
    child = state["child_workflows"][parent]
    spec = state["child_definitions"][parent]

    unless child["phase"] == "planning" and plan["revision"] == child["revision"],
      do: raise(ArgumentError, "Stale child plan revision or phase")

    unless byte_size(Jason.encode!(plan)) <= 32768,
      do: raise(ArgumentError, "Child plan exceeds 32 KiB")

    case plan["decision"] do
      "stop" ->
        unless is_binary(plan["reason"]) and plan["reason"] != "" and is_map(plan["output"]),
          do: raise(ArgumentError, "Child stop requires reason and bounded output")

        child = child |> Map.put("phase", "completed") |> Map.put("stop_reason", plan["reason"])
        state = put_in(state, ["child_workflows", parent], child)

        output =
          Map.put(
            child["boundary_output"],
            "outputs",
            map_fields(plan["output"], spec["outputs"])
          )

        {state, [event(state, parent, :workflow_child_completed)], {:completed, parent, output}}

      "execute" ->
        steps = plan["steps"]

        unless child["round"] < spec["max_rounds"] and is_list(steps) and
                 length(steps) in 1..spec["max_steps_per_round"] and Enum.all?(steps, &is_map/1),
               do: raise(ArgumentError, "Child round budget exceeded or empty graph")

        ids = Enum.map(steps, & &1["id"])

        unless length(ids) == length(Enum.uniq(ids)),
          do: raise(ArgumentError, "Duplicate child step ID")

        Enum.each(steps, fn node ->
          unless is_binary(node["id"]) and Regex.match?(@id, node["id"]) and
                   node["template"] != spec["planner"] and
                   Map.has_key?(spec["templates"], node["template"]) and
                   is_map(node["input"]) and not Map.has_key?(node["input"], "_child") and
                   is_list(node["needs"]) and Enum.all?(node["needs"], &(&1 in ids)),
                 do:
                   raise(ArgumentError, "Unadmitted child template, invalid input or dependency")

          schema = Map.get(spec["templates"][node["template"]], "input_schema", %{})

          case MirrorNeuron.Builtins.StepContract.validate_schema(node["input"], schema) do
            :ok -> :ok
            {:error, reason} -> raise ArgumentError, reason
          end

          if Enum.any?(Map.keys(child["input"]), &Map.has_key?(node["input"], &1)),
            do: raise(ArgumentError, "Child task cannot overwrite mapped parent input")
        end)

        ordered = topological(steps, [])
        round = child["round"] + 1
        prefix = "#{parent}:r#{round}:"
        active = Enum.map(ordered, &(prefix <> &1["id"]))
        hash = :crypto.hash(:sha256, Jason.encode!(plan)) |> Base.encode16(case: :lower)

        child =
          child
          |> Map.merge(%{
            "phase" => "executing",
            "round" => round,
            "revision" => child["revision"] + 1,
            "active" => active,
            "plans" =>
              child["plans"] ++
                [%{"revision" => child["revision"] + 1, "hash" => hash, "plan" => plan}]
          })

        state = put_in(state, ["child_workflows", parent], child)

        state =
          Enum.reduce(ordered, state, fn node, acc ->
            add_instance(
              acc,
              parent,
              prefix <> node["id"],
              node["template"],
              Map.merge(child["input"], node["input"]),
              Enum.map(node["needs"], &(prefix <> &1)),
              "executing",
              now
            )
          end)

        {state, [event(state, parent, :workflow_child_plan_committed)], nil}

      _ ->
        raise ArgumentError, "Child planner must execute or stop"
    end
  end

  defp topological([], done), do: Enum.reverse(done)

  defp topological(nodes, done) do
    ready =
      Enum.find(nodes, fn node ->
        Enum.all?(node["needs"], fn id -> Enum.any?(done, &(&1["id"] == id)) end)
      end)

    if is_nil(ready), do: raise(ArgumentError, "Child graph contains a cycle")
    topological(List.delete(nodes, ready), [ready | done])
  end

  defp add_planner(state, parent, now) do
    child = state["child_workflows"][parent]
    spec = state["child_definitions"][parent]

    add_instance(
      state,
      parent,
      "#{parent}:p#{child["revision"]}",
      spec["planner"],
      child["input"],
      [],
      "planning",
      now
    )
  end

  defp add_instance(state, parent, id, template, input, needs, phase, now) do
    child = state["child_workflows"][parent]
    metadata = Map.take(child, ["parent_step_id", "round", "revision", "phase", "results"])

    node =
      state["child_templates"][template]
      |> Map.merge(%{
        "id" => id,
        "dynamic_instance" => true,
        "parent_step_id" => parent,
        "child_workflow_id" => parent,
        "child_round" => child["round"],
        "child_phase" => phase,
        "template_id" => template,
        "instance_input" => Map.put(input, "_child", metadata),
        "last_event_at" => now
      })

    edges = Enum.map(needs, &%{"id" => "#{&1}->#{id}", "from" => &1, "to" => id})

    state
    |> put_in(["steps", id], node)
    |> Map.update!("step_order", &(&1 ++ [id]))
    |> Map.update!("edges", &(&1 ++ edges))
  end

  defp completed_output(step) do
    cond do
      not is_nil(step["output"]) -> step["output"]
      StagedArtifact.ref?(step["output_ref"]) -> StagedArtifact.resolve!(step["output_ref"])
      true -> raise ArgumentError, "Completed child task has no durable output"
    end
  end

  defp plan_payload(%{"child_plan" => plan}) when is_map(plan), do: plan

  defp plan_payload(value) when is_map(value) do
    resolved = StagedArtifact.resolve_output!(value)

    nested =
      if resolved != value,
        do: resolved,
        else: value["outputs"] || value["result"] || value["payload"]

    if is_map(nested),
      do: plan_payload(nested),
      else: raise(ArgumentError, "Missing child_plan output")
  end

  defp plan_payload(_), do: raise(ArgumentError, "Child planner output must be an object")

  defp map_fields(value, fields) do
    Map.new(fields, fn {key, path} ->
      result =
        Enum.reduce(path, value, fn part, acc ->
          Map.fetch!(StagedArtifact.resolve_output!(acc), part)
        end)

      {key, result}
    end)
  end

  defp event(state, parent, type) do
    child = state["child_workflows"][parent]

    %{
      type: type,
      parent_step_id: parent,
      child_workflow_id: parent,
      round: child["round"],
      revision: child["revision"],
      phase: child["phase"]
    }
  end
end
