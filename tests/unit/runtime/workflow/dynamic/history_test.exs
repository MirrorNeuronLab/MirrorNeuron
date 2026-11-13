defmodule MirrorNeuron.Runtime.DynamicWorkflow.HistoryTest do
  use MirrorNeuron.DynamicWorkflowCase, async: true

  alias MirrorNeuron.Runtime.WorkflowLedger

  test "service fanout retires completed finite work into bounded history" do
    state = running_state("checkpoint_fanout")
    {state, _message} = start_controller(state)

    {state, _events, [{:redeliver, "followup_1", "followup_worker", trigger}]} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        service_patch(),
        "2026-07-29T10:00:01.000Z"
      )

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "followup_worker",
        trigger,
        "2026-07-29T10:00:02.000Z"
      )

    attempt = get_in(state, ["steps", "followup_1", "current_attempt"])

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "followup_worker",
        :workflow_step_completed,
        %{
          "step_id" => "followup_1",
          "attempt_id" => attempt["attempt_id"],
          "idempotency_key" => attempt["idempotency_key"]
        },
        "2026-07-29T10:00:03.000Z"
      )

    refute Map.has_key?(state["steps"], "followup_1")
    refute Map.has_key?(state["dynamic_patch_instances"], "service-item-1")
    assert [%{"patch_id" => "service-item-1", "steps" => [retired]}] = state["dynamic_history"]
    assert retired["status"] == "completed"
    assert Enum.any?(events, &(&1.type == :workflow_dynamic_steps_retired))
  end

  test "terminal dynamic instances do not consume the active-step limit" do
    state = running_state("replace_path") |> put_in(["dynamic_limits", "max_active_steps"], 1)
    {state, _message} = start_controller(state)

    {state, _events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        replace_path_patch("path-1", "followup_1", 0, remove_direct?: true),
        "2026-07-29T10:00:01.000Z"
      )

    state =
      state
      |> put_in(["steps", "followup_1", "status"], "completed")
      |> put_in(["steps", "followup_1", "attempt_count"], 1)

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        replace_path_patch("path-2", "followup_2", 1),
        "2026-07-29T10:00:02.000Z"
      )

    assert state["graph_revision"] == 2
    assert Map.has_key?(state["steps"], "followup_2")
    assert Enum.any?(events, &(&1.type == :workflow_graph_patch_applied))
  end
end
