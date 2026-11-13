defmodule MirrorNeuron.Runtime.WorkflowLedger.InvariantsTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Runtime.WorkflowLedger
  alias MirrorNeuron.Runtime.WorkflowLedger.Dependencies

  test "a handled failure records its attempt once with the failure outcome" do
    {state, _} = dag_state([{"a", "all_success", "continue_partial"}], []) |> receive_message("a")
    attempt_id = state["steps"]["a"]["current_attempt"]["attempt_id"]

    {state, _events, []} = on_failed(state, "a", "worker exited")

    assert state["steps"]["a"]["status"] == "partial"

    assert [%{"attempt_id" => ^attempt_id, "status" => "failed"}] =
             state["steps"]["a"]["attempts"]

    assert state["steps"]["a"]["current_attempt"] == nil
  end

  test "a late started event during retry wait preserves the event result contract" do
    {state, []} =
      WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running(timestamp(0))

    {state, _} = receive_message(state, "step_a")
    attempt_id = state["steps"]["step_a"]["current_attempt"]["attempt_id"]
    {state, _, []} = on_failed(state, "step_a", "retry me")

    assert {next, [event], []} =
             WorkflowLedger.on_agent_event(
               state,
               "step_a",
               :workflow_step_started,
               %{"attempt_id" => attempt_id},
               timestamp(2)
             )

    assert event.type == :workflow_step_stale_output_ignored
    assert next["steps"]["step_a"]["status"] == "retry_wait"
    assert next["steps"]["step_a"]["current_attempt"] == nil
    assert next["steps"]["step_a"]["attempts"] == state["steps"]["step_a"]["attempts"]
  end

  test "recovery retains attempt identity but discards in-flight inspection tokens" do
    {state, _} = dag_state(["a"], []) |> receive_message("a")
    attempt = state["steps"]["a"]["current_attempt"]
    saved = put_in(state, ["steps", "a", "inspection"], %{"token" => "old-owner-token"})
    saved = put_in(saved, ["steps", "unknown"], %{"id" => "unknown", "status" => "running"})
    saved = Jason.decode!(Jason.encode!(saved))

    restored =
      WorkflowLedger.new(dag_manifest(["a"], []), dag_nodes(["a"]), %{"workflow_state" => saved})

    assert restored["run_id"] == state["run_id"]
    assert restored["steps"]["a"]["current_attempt"] == attempt
    refute Map.has_key?(restored["steps"]["a"], "inspection")
    refute Map.has_key?(restored["steps"], "unknown")
  end

  test "compact snapshots omit message bodies and instance inputs while retaining output references" do
    state = dag_state(["a"], [])
    reference = %{"artifact_id" => "durable-output"}

    state =
      update_in(
        state,
        ["steps", "a"],
        &Map.merge(&1, %{
          "output" => %{"private" => "output"},
          "output_ref" => reference,
          "last_message" => %{"private" => "input"},
          "instance_input" => %{"private" => "parameters"}
        })
      )

    compact = WorkflowLedger.compact_snapshot(state)
    refute Map.has_key?(compact, "messages")
    refute Map.has_key?(compact["steps"]["a"], "last_message")
    refute Map.has_key?(compact["steps"]["a"], "output")
    refute Map.has_key?(compact["steps"]["a"], "instance_input")
    assert compact["steps"]["a"]["output_ref"] == reference
    assert state["steps"]["a"]["output"] == %{"private" => "output"}
  end

  for {rule, statuses, satisfied, impossible} <- [
        {%{"rule" => "all_success"}, ["completed", "running"], false, false},
        {%{"rule" => "all_success"}, ["completed", "failed"], false, true},
        {%{"rule" => "all_done"}, ["partial", "skipped"], true, false},
        {%{"rule" => "one_success"}, ["partial", "skipped"], false, true},
        {%{"rule" => "one_done"}, ["failed", "running"], true, false},
        {%{"rule" => "one_failed"}, ["failed", "running"], true, false},
        {%{"rule" => "none_failed_min_one_success"}, ["completed", "skipped"], true, false},
        {%{"rule" => "quorum_success", "quorum" => 2}, ["failed", "running"], false, true},
        {%{"rule" => "quorum_success", "quorum" => 2}, ["completed", "running"], false, false}
      ] do
    test "#{rule["rule"]} with #{Enum.join(statuses, ", ")} has a consistent activation decision" do
      state = dag_state(["a", "b", "join"], [edge("a", "join"), edge("b", "join")])

      state =
        Enum.zip(["a", "b"], unquote(statuses))
        |> Enum.reduce(state, fn {id, status}, acc ->
          put_in(acc, ["steps", id, "status"], status)
        end)

      step = Map.put(state["steps"]["join"], "trigger_rule", unquote(Macro.escape(rule)))

      assert Dependencies.dependencies_satisfied?(state, step) == unquote(satisfied)
      assert Dependencies.dependencies_impossible?(state, step) == unquote(impossible)
    end
  end
end
