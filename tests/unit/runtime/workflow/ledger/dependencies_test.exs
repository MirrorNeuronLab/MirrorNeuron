defmodule MirrorNeuron.Runtime.WorkflowLedger.DependenciesTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.WorkflowLedger

  test "blocks early join messages and redelivers when dependencies are satisfied" do
    {state, []} =
      WorkflowLedger.new(join_manifest(), join_runtime_nodes())
      |> WorkflowLedger.job_running()

    join_message = Message.new("job-1", "step_a", "join_step", "a_done", %{"value" => "early"})

    {state, [blocked]} =
      WorkflowLedger.on_message_received(
        state,
        "join_step",
        join_message,
        "2026-06-02T16:00:00.000Z"
      )

    assert blocked.type == :workflow_step_blocked
    assert get_in(state, ["steps", "join_step", "status"]) == "blocked"

    {state, [completed], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :workflow_step_attempt_completed,
        %{"status" => "completed"},
        "2026-06-02T16:00:01.000Z"
      )

    assert completed.type == :workflow_step_completed

    {state, [], [{:redeliver, "join_step", "join_step", redelivered}]} =
      reconcile(state, "2026-06-02T16:00:02.000Z")

    assert redelivered == join_message
    assert get_in(state, ["steps", "join_step", "status"]) == "queued"
  end

  test "runs a linear pipeline in dependency order" do
    state = dag_state(["a", "b", "c"], [edge("a", "b"), edge("b", "c")])
    {state, [_]} = receive_message(state, "b")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    {state, _, [{:redeliver, "b", "b", message}]} = reconcile(state, timestamp(2))
    state = state |> receive_workflow_message(message) |> elem(0) |> complete_step("b")
    {state, [_]} = receive_message(state, "c")
    state = complete_step(state, "c")
    assert WorkflowLedger.completed?(state)
  end

  test "fans one completed step out to parallel downstream steps" do
    state = dag_state(["a", "b", "c"], [edge("a", "b"), edge("a", "c")])
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    state = state |> receive_message("b") |> elem(0)
    state = state |> receive_message("c") |> elem(0)

    assert get_in(state, ["steps", "b", "status"]) == "running"
    assert get_in(state, ["steps", "c", "status"]) == "running"
  end

  test "fans in only after every required parent succeeds" do
    state =
      dag_state(["a", "b", "c", "join"], [edge("a", "join"), edge("b", "join"), edge("c", "join")])

    {state, [_]} = receive_message(state, "join")

    state =
      Enum.reduce(["a", "b", "c"], state, fn step_id, acc ->
        acc |> receive_message(step_id) |> elem(0) |> complete_step(step_id)
      end)

    {state, _, [{:redeliver, "join", "join", message}]} =
      reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "starts a one-success join after the first successful parent" do
    state = dag_state(["a", "b", {"join", "one_success"}], [edge("a", "join"), edge("b", "join")])
    {state, [_]} = receive_message(state, "join")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")

    {state, _, [{:redeliver, "join", "join", message}]} =
      reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "starts a one-done join after a handled failure" do
    state =
      dag_state([{"a", "all_success", "continue_partial"}, {"join", "one_done"}], [
        edge("a", "join")
      ])

    state = state |> receive_message("a") |> elem(0)

    {state, events, [{:redeliver, "join", "join", message}]} =
      WorkflowLedger.on_agent_failed(state, "a", "provider unavailable", timestamp(1))

    assert Enum.any?(events, &(&1.type == :workflow_step_failed))
    assert get_in(state, ["steps", "a", "terminal_outcome"]) == "failed"
    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "runs a failure handler after the first handled failure" do
    state =
      dag_state([{"a", "all_success", "continue_partial"}, {"alert", "one_failed"}], [
        edge("a", "alert")
      ])

    state = state |> receive_message("a") |> elem(0)

    {state, _, [{:redeliver, "alert", "alert", message}]} =
      WorkflowLedger.on_agent_failed(state, "a", "provider unavailable", timestamp(1))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "alert", "status"]) == "running"
  end

  test "waits for every terminal parent before cleanup" do
    state =
      dag_state(
        ["a", {"b", "all_success", "continue_partial"}, {"cleanup", "all_done"}],
        [edge("a", "cleanup"), edge("b", "cleanup")]
      )

    {state, [_]} = receive_message(state, "cleanup")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    state = state |> receive_message("b") |> elem(0)
    state = state |> on_failed("b", "failed work") |> elem(0)

    {state, _, [{:redeliver, "cleanup", "cleanup", message}]} =
      reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "cleanup", "status"]) == "running"
  end

  test "joins a selected branch when other branches are skipped" do
    state =
      dag_state(
        ["selected", "skipped", {"join", "none_failed_min_one_success"}],
        [edge("selected", "join"), edge("skipped", "join")]
      )

    {state, [_]} = receive_message(state, "join")
    state = state |> receive_message("selected") |> elem(0) |> complete_step("selected")

    {state, _, _} =
      WorkflowLedger.on_agent_event(
        state,
        "skipped",
        :workflow_step_skipped,
        %{"reason" => "branch not selected"},
        timestamp(1)
      )

    {state, _, [{:redeliver, "join", "join", message}]} =
      reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "advances through a fallback chain only after each handled failure" do
    state =
      dag_state(
        [
          {"primary", "all_success", "continue_partial"},
          {"fallback", "one_failed", "continue_partial"},
          {"emergency", "one_failed"}
        ],
        [edge("primary", "fallback"), edge("fallback", "emergency")]
      )

    state = state |> receive_message("primary") |> elem(0)

    {state, _, [{:redeliver, "fallback", "fallback", fallback_message}]} =
      on_failed(state, "primary", "primary unavailable")

    {state, [_]} = receive_workflow_message(state, fallback_message)

    {state, _, [{:redeliver, "emergency", "emergency", emergency_message}]} =
      on_failed(state, "fallback", "fallback unavailable")

    {state, [_]} = receive_workflow_message(state, emergency_message)
    assert get_in(state, ["steps", "emergency", "status"]) == "running"
  end

  test "releases a quorum join after the configured number of successes" do
    state =
      dag_state(
        ["a", "b", "c", {"join", %{"rule" => "quorum_success", "quorum" => 2}}],
        [edge("a", "join"), edge("b", "join"), edge("c", "join")]
      )

    {state, [_]} = receive_message(state, "join")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    state = state |> receive_message("b") |> elem(0) |> complete_step("b")

    {state, _, [{:redeliver, "join", "join", message}]} =
      reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "runs teardown after failed work when its all-done trigger is satisfied" do
    state =
      dag_state(
        ["setup", {"work", "all_success", "continue_partial"}, {"teardown", "all_done"}],
        [edge("setup", "work"), edge("work", "teardown")]
      )

    state = state |> receive_message("setup") |> elem(0) |> complete_step("setup")
    state = state |> receive_message("work") |> elem(0)

    {state, _, [{:redeliver, "teardown", "teardown", message}]} =
      on_failed(state, "work", "work failed")

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "teardown", "status"]) == "running"
  end

  test "continues after a sensor receives an external event" do
    state = dag_state(["sensor", "continue"], [edge("sensor", "continue")])

    external =
      Message.new("job", "external", "sensor", "file_arrived", %{"path" => "inbox/report.csv"})

    {state, [_]} = receive_workflow_message(state, external)
    state = complete_step(state, "sensor")
    {state, [_]} = receive_message(state, "continue")
    assert get_in(state, ["steps", "continue", "status"]) == "running"
  end
end
