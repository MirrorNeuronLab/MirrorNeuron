defmodule MirrorNeuron.Runtime.DynamicWorkflow.ControllersTest do
  use MirrorNeuron.DynamicWorkflowCase, async: true

  alias MirrorNeuron.Runtime.WorkflowLedger

  test "checkpoint fanout checkpoints the controller and releases roots immediately" do
    state = running_state("checkpoint_fanout")
    {state, _message} = start_controller(state)

    patch = %{
      "patch_id" => "service-item-1",
      "base_revision" => 0,
      "region_id" => "service_work",
      "operations" => [
        %{
          "op" => "add_step",
          "id" => "followup_1",
          "template" => "followup_research",
          "with" => %{"record_id" => 7}
        },
        %{
          "op" => "add_edge",
          "id" => "controller_to_followup",
          "from" => "inspect",
          "to" => "followup_1"
        }
      ]
    }

    {state, events, actions} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        patch,
        "2026-07-29T10:00:01.000Z"
      )

    assert Enum.any?(events, &(&1.type == :workflow_graph_patch_applied))
    assert get_in(state, ["steps", "inspect", "status"]) == "waiting"
    assert [{:redeliver, "followup_1", "followup_worker", _trigger}] = actions
  end

  test "a controller checkpoint is accepted once and stale controller events are fenced" do
    state = running_state("checkpoint_fanout")
    {state, message} = start_controller(state)
    attempt_id = message["headers"]["mn.workflow.attempt_id"]

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_controller_checkpoint,
        %{"region_id" => "service_work", "attempt_id" => attempt_id},
        "2026-07-29T10:00:01.000Z"
      )

    assert Enum.any?(events, &(&1.type == :workflow_controller_checkpointed))
    assert get_in(state, ["steps", "inspect", "status"]) == "waiting"

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_controller_checkpoint,
        %{"region_id" => "service_work", "attempt_id" => attempt_id},
        "2026-07-29T10:00:02.000Z"
      )

    assert Enum.any?(events, &(&1.type == :workflow_step_stale_output_ignored))
    assert get_in(state, ["steps", "inspect", "status"]) == "waiting"
  end

  test "a rejected patch fences a late completion from the rejected attempt" do
    state = running_state("replace_path") |> put_in(["steps", "inspect", "max_attempts"], 2)
    {state, message} = start_controller(state)
    attempt_id = message["headers"]["mn.workflow.attempt_id"]

    {state, _events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        %{
          "patch_id" => "stale-retry",
          "base_revision" => 9,
          "region_id" => "research_followups",
          "operations" => [%{"op" => "remove_edge", "id" => "inspect_to_report"}],
          "attempt_id" => attempt_id
        },
        "2026-07-29T10:00:01.000Z"
      )

    assert get_in(state, ["steps", "inspect", "status"]) == "retry_wait"

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_step_completed,
        %{"step_id" => "inspect", "attempt_id" => attempt_id},
        "2026-07-29T10:00:02.000Z"
      )

    assert get_in(state, ["steps", "inspect", "status"]) == "retry_wait"
    assert Enum.any?(events, &(&1.type == :workflow_step_stale_output_ignored))
  end
end
