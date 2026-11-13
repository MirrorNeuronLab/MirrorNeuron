defmodule MirrorNeuron.Runtime.WorkflowLedger.Branches do
  @moduledoc "Applies branch selections and propagates skips through downstream paths."

  alias MirrorNeuron.Runtime.WorkflowLedger.Dependencies
  alias MirrorNeuron.Runtime.WorkflowLedger.Events
  alias MirrorNeuron.Runtime.WorkflowLedger.Resolution
  alias MirrorNeuron.Runtime.WorkflowLedger.State

  def apply_branch_selection(state, step, payload, now) do
    selected = selected_branch_ids(payload)

    candidates =
      state
      |> outgoing_edges(step["id"])
      |> Enum.map(&Map.get(&1, "to"))
      |> Enum.uniq()

    skipped = Enum.reject(candidates, &(&1 in selected))

    {next_state, skip_events, skip_actions} =
      Enum.reduce(skipped, {state, [], []}, fn step_id, {acc_state, events, actions} ->
        {next_state, next_events, next_actions} =
          skip_branch_path(acc_state, step_id, "not selected by branch #{step["id"]}", now)

        {next_state, events ++ next_events, actions ++ next_actions}
      end)

    event =
      Events.workflow_event(:workflow_branch_selected, step, %{
        "selected" => selected,
        "skipped" => skipped
      })

    {next_state, [event | skip_events], skip_actions}
  end

  def skip_downstream_steps(state, step, payload, now) do
    if Map.get(payload, "skip_downstream") == true do
      state
      |> descendant_step_ids(step["id"])
      |> Enum.reduce({state, [], []}, fn step_id, {acc_state, events, actions} ->
        case State.get_step(acc_state, step_id) do
          nil ->
            {acc_state, events, actions}

          descendant ->
            {next_state, next_events, next_actions} =
              Resolution.skip_step(
                acc_state,
                descendant,
                "short-circuited by #{step["id"]}",
                now,
                terminate?: true
              )

            {next_state, events ++ next_events, actions ++ next_actions}
        end
      end)
    else
      {state, [], []}
    end
  end

  defp skip_branch_path(state, step_id, reason, now) do
    case State.get_step(state, step_id) do
      nil ->
        {state, [], []}

      step ->
        {state, events, actions} = Resolution.skip_step(state, step, reason, now)

        {state, cascade_events, cascade_actions} =
          cascade_branch_skips(state, step_id, reason, now)

        {state, events ++ cascade_events, actions ++ cascade_actions}
    end
  end

  defp cascade_branch_skips(state, skipped_step_id, reason, now) do
    state
    |> outgoing_edges(skipped_step_id)
    |> Enum.map(&Map.get(&1, "to"))
    |> Enum.uniq()
    |> Enum.reduce({state, [], []}, fn child_id, {acc_state, events, actions} ->
      child = State.get_step(acc_state, child_id)

      if is_map(child) and not State.step_terminal?(child) and
           all_parents_skipped?(acc_state, child) do
        {next_state, next_events, next_actions} =
          skip_branch_path(acc_state, child_id, reason, now)

        {next_state, events ++ next_events, actions ++ next_actions}
      else
        {acc_state, events, actions}
      end
    end)
  end

  defp all_parents_skipped?(state, step) do
    case Dependencies.incoming_edges(state, step) do
      [] ->
        false

      edges ->
        Enum.all?(edges, fn edge ->
          get_in(state, ["steps", Map.get(edge, "from"), "status"]) == "skipped"
        end)
    end
  end

  defp selected_branch_ids(payload) do
    values = Map.get(payload, "branches", Map.get(payload, "branch", []))

    values
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp outgoing_edges(%{"edges" => edges}, step_id) when is_list(edges) do
    Enum.filter(edges, &(Map.get(&1, "from") == step_id))
  end

  defp outgoing_edges(_state, _step_id), do: []

  defp descendant_step_ids(state, step_id) do
    descendants(state, MapSet.new([step_id]), [step_id])
    |> MapSet.delete(step_id)
    |> MapSet.to_list()
  end

  defp descendants(_state, seen, []), do: seen

  defp descendants(state, seen, [step_id | rest]) do
    next_ids =
      state
      |> outgoing_edges(step_id)
      |> Enum.map(&Map.get(&1, "to"))
      |> Enum.reject(&MapSet.member?(seen, &1))

    descendants(state, Enum.reduce(next_ids, seen, &MapSet.put(&2, &1)), rest ++ next_ids)
  end
end
