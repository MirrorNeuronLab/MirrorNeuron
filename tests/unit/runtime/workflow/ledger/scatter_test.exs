defmodule MirrorNeuron.Runtime.WorkflowLedger.ScatterTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Runtime.WorkflowLedger

  test "scatters items into mapped steps and gathers their outputs" do
    state =
      dag_state(["source", "worker", "collect"], [
        edge("source", "worker"),
        edge("worker", "collect")
      ])

    {state, [_]} = receive_message(state, "source")

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "source",
        :workflow_step_scatter,
        %{"target" => "worker", "items" => [%{"id" => 1}, %{"id" => 2}]},
        timestamp(1)
      )

    assert Enum.any?(events, &(&1.type == :workflow_step_scattered))

    assert get_in(state, ["steps", "worker", "status"]) == "skipped"

    state = complete_step(state, "source")
    {state, _, worker_actions} = reconcile(state, timestamp(2))

    assert Enum.map(worker_actions, fn {:redeliver, step_id, _, _} -> step_id end) == [
             "worker[0]",
             "worker[1]"
           ]

    state =
      Enum.reduce(worker_actions, state, fn {:redeliver, _step_id, _agent_id, message}, acc ->
        acc |> receive_workflow_message(message) |> elem(0)
      end)

    {state, [_]} = receive_message(state, "collect")
    state = state |> complete_step("worker[0]") |> complete_step("worker[1]")

    {state, _, [{:redeliver, "collect", "collect", message}]} =
      reconcile(state, timestamp(3))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "collect", "status"]) == "running"
  end

  test "restores mapped items and expanded edges after a coordinator restart" do
    step_specs = ["source", "worker", "collect"]
    edges = [edge("source", "worker"), edge("worker", "collect")]
    state = dag_state(step_specs, edges)
    {state, [_]} = receive_message(state, "source")

    {state, _, []} =
      WorkflowLedger.on_agent_event(
        state,
        "source",
        :workflow_step_scatter,
        %{"target" => "worker", "items" => [%{"id" => 1}, %{"id" => 2}]},
        timestamp(1)
      )

    restored =
      WorkflowLedger.new(
        dag_manifest(step_specs, edges),
        dag_nodes(step_specs),
        %{"workflow_state" => state}
      )

    assert Map.has_key?(restored["steps"], "worker[0]")
    assert Map.has_key?(restored["steps"], "worker[1]")
    assert Enum.any?(restored["edges"], &(&1["from"] == "worker[0]" and &1["to"] == "collect"))
  end

  test "tracks a mapped worker failure against the mapped item" do
    state = dag_state(["source", "worker"], [edge("source", "worker")])
    {state, [_]} = receive_message(state, "source")

    {state, _, _} =
      WorkflowLedger.on_agent_event(
        state,
        "source",
        :workflow_step_scatter,
        %{"target" => "worker", "items" => [%{"id" => 1}]},
        timestamp(1)
      )

    state = complete_step(state, "source")

    {state, _, [{:redeliver, "worker[0]", "worker", message}]} =
      reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)

    {state, _, [{:fail_job, "worker[0]", "worker lost"}]} =
      WorkflowLedger.on_agent_failed(state, "worker", "worker lost", timestamp(3))

    assert get_in(state, ["steps", "worker[0]", "status"]) == "failed"
  end
end
