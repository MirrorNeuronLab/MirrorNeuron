defmodule MirrorNeuron.Runtime.WorkflowLedger.BranchesTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Runtime.WorkflowLedger

  test "selects branch targets and skips the unselected branch" do
    state =
      dag_state(
        ["router", "left", "right", {"join", "none_failed_min_one_success"}],
        [
          edge("router", "left"),
          edge("router", "right"),
          edge("left", "join"),
          edge("right", "join")
        ]
      )

    state = state |> receive_message("router") |> elem(0)

    {state, events, _} =
      WorkflowLedger.on_agent_event(
        state,
        "router",
        :workflow_step_branch,
        %{"branches" => ["left"]},
        timestamp(1)
      )

    assert Enum.any?(events, &(&1.type == :workflow_branch_selected))
    assert get_in(state, ["steps", "right", "status"]) == "skipped"
    assert get_in(state, ["steps", "join", "status"]) == "pending"
  end

  test "short circuits and skips every downstream step" do
    state =
      dag_state(["guard", "work", "cleanup"], [edge("guard", "work"), edge("work", "cleanup")])

    state = state |> receive_message("guard") |> elem(0)

    {state, events, _} =
      WorkflowLedger.on_agent_event(
        state,
        "guard",
        :workflow_step_skipped,
        %{"reason" => "no input", "skip_downstream" => true},
        timestamp(1)
      )

    assert Enum.count(events, &(&1.type == :workflow_step_skipped)) == 3
    assert Enum.all?(Map.values(state["steps"]), &(Map.get(&1, "status") == "skipped"))
  end
end
