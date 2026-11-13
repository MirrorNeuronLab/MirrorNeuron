defmodule MirrorNeuron.Runtime.WorkflowLedger.Scatter do
  @moduledoc "Expands bounded scatter items into independent mapped workflow steps."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.WorkflowLedger.Definitions
  alias MirrorNeuron.Runtime.WorkflowLedger.Events
  alias MirrorNeuron.Runtime.WorkflowLedger.Messages
  alias MirrorNeuron.Runtime.WorkflowLedger.Resolution
  alias MirrorNeuron.Runtime.WorkflowLedger.State
  alias MirrorNeuron.Runtime.WorkflowLedger.Values

  @default_max_scatter_items 1_000

  def expand_scatter(state, source_step, payload, now) do
    targets = scatter_targets(payload)
    items = Map.get(payload, "items")
    max_items = Values.positive_int(Map.get(payload, "max_items"), @default_max_scatter_items)

    cond do
      targets == [] ->
        scatter_rejected(state, source_step, "scatter requires target or targets", now)

      not is_list(items) ->
        scatter_rejected(state, source_step, "scatter items must be a list", now)

      items == [] ->
        {state, [Events.workflow_event(:workflow_step_scattered, source_step, %{"count" => 0})],
         []}

      length(items) > max_items ->
        scatter_rejected(state, source_step, "scatter item count exceeds #{max_items}", now)

      Enum.any?(targets, &(not is_map(State.get_step(state, &1)))) ->
        scatter_rejected(state, source_step, "scatter target does not name a workflow step", now)

      Enum.any?(targets, &State.step_terminal?(State.get_step(state, &1))) ->
        scatter_rejected(state, source_step, "scatter target is already terminal", now)

      true ->
        expand_scatter_items(state, source_step, targets, items, now)
    end
  end

  defp expand_scatter_items(state, source_step, targets, items, now) do
    instances =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        target = Enum.at(targets, rem(index, length(targets)))
        base = State.get_step(state, target)
        instance_id = "#{target}[#{index}]"

        %{
          "id" => instance_id,
          "target" => target,
          "item" => item,
          "step" =>
            Definitions.initial_step(
              base
              |> Map.put("id", instance_id)
              |> Map.put("label", "#{base["label"]} [#{index}]")
              |> Map.put("map_index", index)
              |> Map.put("map_item", item)
            )
        }
      end)

    instance_ids_by_target = Enum.group_by(instances, & &1["target"], & &1["id"])
    target_steps = Enum.map(targets, &State.get_step(state, &1))

    {state, target_events} =
      Enum.reduce(target_steps, {state, []}, fn target, {acc_state, events} ->
        {next_state, next_events} =
          Resolution.resolve_step(
            acc_state,
            target,
            "skipped",
            %{"reason" => "expanded into mapped work items"},
            now,
            outcome: "mapped"
          )

        {next_state, events ++ next_events}
      end)

    edges = expand_scatter_edges(state["edges"], instance_ids_by_target)

    mapped_steps =
      Map.new(instances, fn instance ->
        step = instance["step"]

        message =
          Message.new(
            Map.get(state, "job_id") || State.run_id(state),
            "workflow_ledger",
            State.primary_agent_id(step),
            "workflow_scatter_item",
            %{"item" => instance["item"], "map_index" => step["map_index"]},
            timestamp: now,
            class: "command"
          )
          |> then(&Messages.decorate_step_message(state, step, &1))

        {step["id"], Map.put(step, "last_message", message)}
      end)

    state =
      state
      |> Map.put("edges", edges)
      |> Map.update!("steps", fn steps ->
        Map.merge(steps, mapped_steps)
      end)
      |> Map.update!(
        "step_order",
        &(&1 ++ Enum.map(instances, fn instance -> instance["id"] end))
      )
      |> State.put_updated_at(now)

    event =
      Events.workflow_event(:workflow_step_scattered, source_step, %{
        "count" => length(instances),
        "targets" => targets,
        "instance_ids" => Enum.map(instances, & &1["id"])
      })

    {state, [event | target_events], []}
  end

  defp scatter_rejected(state, step, reason, now) do
    step = State.touch_step(step, now)
    state = State.put_step(state, step) |> State.put_updated_at(now)

    {state, [Events.workflow_event(:workflow_step_scatter_rejected, step, %{"reason" => reason})],
     []}
  end

  defp expand_scatter_edges(edges, instance_ids_by_target) do
    Enum.flat_map(edges, fn edge ->
      from_ids = Map.get(instance_ids_by_target, Map.get(edge, "from"), [Map.get(edge, "from")])
      to_ids = Map.get(instance_ids_by_target, Map.get(edge, "to"), [Map.get(edge, "to")])

      for from_id <- from_ids, to_id <- to_ids do
        edge
        |> Map.put("from", from_id)
        |> Map.put("to", to_id)
      end
    end)
  end

  defp scatter_targets(payload) do
    targets = Map.get(payload, "targets")

    values =
      cond do
        is_list(targets) -> targets
        is_binary(Map.get(payload, "target")) -> [Map.get(payload, "target")]
        true -> []
      end

    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end
end
