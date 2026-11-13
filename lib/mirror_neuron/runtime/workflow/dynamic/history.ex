defmodule MirrorNeuron.Runtime.DynamicWorkflow.History do
  @moduledoc "Tracks patch instances and retires completed service graphs into bounded history."

  alias MirrorNeuron.Runtime.DynamicWorkflow.State

  @history_default 256
  @terminal_statuses ["completed", "partial", "skipped", "failed"]

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

  def record_patch_instances(state, request, region, delta, revision, now) do
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

  def detach_patch_instance(state, step) do
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
      graph_revision: State.graph_revision(state),
      step_ids: step_ids,
      timestamp: now
    }

    {next, event}
  end
end
