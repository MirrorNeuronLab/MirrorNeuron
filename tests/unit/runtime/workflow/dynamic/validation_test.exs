defmodule MirrorNeuron.Runtime.DynamicWorkflow.ValidationTest do
  use MirrorNeuron.DynamicWorkflowCase, async: true

  alias MirrorNeuron.Runtime.DynamicWorkflow

  @now "2026-07-29T10:00:01.000Z"

  for {field, value} <- [{"patch_id", %{}}, {"region_id", ["nested"]}] do
    test "rejects a malformed #{field} without mutating the graph" do
      {state, _} = running_state("replace_path") |> start_controller()

      patch =
        replace_path_patch("patch-1", "followup", 0)
        |> Map.put(unquote(field), unquote(Macro.escape(value)))

      assert {:error, ^state, event} = apply_patch(state, patch)
      assert event.type == :workflow_graph_patch_rejected
    end
  end

  test "rejects a malformed operation instead of crashing the controller" do
    {state, _} = running_state("replace_path") |> start_controller()
    patch = replace_path_patch("patch-1", "followup", 0)
    patch = Map.put(patch, "operations", [%{"op" => %{}}])

    assert {:error, ^state, event} = apply_patch(state, patch)
    assert event.reason =~ "unsupported patch operation"
  end

  test "a failed operation rolls back preceding step additions" do
    {state, _} = running_state("replace_path") |> start_controller()
    patch = replace_path_patch("patch-1", "followup", 0)

    patch =
      update_in(patch, ["operations"], &(&1 ++ [%{"op" => "remove_edge", "id" => "missing"}]))

    assert {:error, ^state, event} = apply_patch(state, patch)
    assert event.reason =~ "unknown edge"
  end

  test "rejects a structured label before adding its step" do
    {state, _} = running_state("replace_path") |> start_controller()
    patch = replace_path_patch("patch-1", "followup", 0)
    [add | rest] = patch["operations"]
    patch = Map.put(patch, "operations", [Map.put(add, "label", %{}) | rest])

    assert {:error, ^state, event} = apply_patch(state, patch)
    assert event.reason =~ "label must be a string"
  end

  test "cycle validation rejects an otherwise valid sequence of mutations atomically" do
    {state, _} = running_state("replace_path") |> start_controller()
    patch = replace_path_patch("patch-1", "followup", 0)
    reverse = %{"op" => "add_edge", "id" => "reverse", "from" => "report", "to" => "followup"}
    patch = update_in(patch, ["operations"], &(&1 ++ [reverse]))

    assert {:error, ^state, event} = apply_patch(state, patch)
    assert event.reason =~ "cyclic"
  end

  test "a replacement path must keep the fixed exit reachable" do
    {state, _} = running_state("replace_path") |> start_controller()
    patch = replace_path_patch("patch-1", "followup", 0, remove_direct?: true)
    patch = update_in(patch, ["operations"], &Enum.reject(&1, fn op -> op["to"] == "report" end))

    assert {:error, ^state, event} = apply_patch(state, patch)
    assert event.reason =~ "fixed exit reachable"
  end

  test "recovery preserves patch deduplication and rejects changed replay content" do
    {state, _} = running_state("replace_path") |> start_controller()
    patch = replace_path_patch("patch-1", "followup", 0)
    assert {:ok, patched, _, "replace_path"} = apply_patch(state, patch)
    restored = Jason.decode!(Jason.encode!(patched))

    assert {:duplicate, ^restored, _, "replace_path"} = apply_patch(restored, patch)
    changed = put_in(patch, ["base_revision"], 1)
    assert {:error, ^restored, event} = apply_patch(restored, changed)
    assert event.reason =~ "different content"
  end

  test "unencodable instance input is rejected even with a large byte budget" do
    {state, _} = running_state("replace_path") |> start_controller()
    state = put_in(state, ["dynamic_limits", "max_instance_input_bytes"], 1_000_000)
    patch = replace_path_patch("patch-1", "followup", 0)
    [add | rest] = patch["operations"]
    patch = Map.put(patch, "operations", [Map.put(add, "with", %{"invalid" => self()}) | rest])

    assert {:error, ^state, event} = apply_patch(state, patch)
    assert event.reason =~ "JSON"
  end

  defp apply_patch(state, patch),
    do: DynamicWorkflow.apply_patch(state, state["steps"]["inspect"], patch, @now)
end
