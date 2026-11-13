defmodule MirrorNeuron.Runtime.WorkflowLedger.AttemptsTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.WorkflowLedger

  test "runner failures retain the exception and structured diagnostics through terminal actions" do
    state = dag_state(["a"], []) |> receive_message("a") |> elem(0)
    state = put_in(state, ["agent_to_step", "specialist"], "a")

    reason = %{
      "exit_code" => 1,
      "runner" => "host_local",
      "attempts" => 1,
      "logs" =>
        String.duplicate("stack frame\n", 600) <>
          "FileNotFoundError: source manifest is unavailable"
    }

    {state, events, [{:fail_job, "a", error}]} =
      WorkflowLedger.on_agent_failed(state, "specialist", reason, timestamp(1))

    assert error["code"] == "runtime.command.failed"
    assert error["details"]["exit_code"] == 1
    assert error["details"]["agent_id"] == "specialist"
    assert error["details"]["logs"] =~ "FileNotFoundError: source manifest is unavailable"

    assert error["desc"] ==
             "Command exited with code 1: FileNotFoundError: source manifest is unavailable"

    assert get_in(state, ["steps", "a", "terminal_reason"]) == error["desc"]
    failed = Enum.find(events, &(&1.type == :workflow_step_failed))
    assert failed["error"]["details"]["exit_code"] == 1
    assert failed["reason"] == error["desc"]
  end

  test "tracks workflow attempts, retries timed out steps, and fails after attempts are exhausted" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "start"})

    decorated = WorkflowLedger.decorate_message(state, "step_a", message)
    assert decorated["headers"]["mn.workflow.step_id"] == "step_a"

    {state, [started]} =
      WorkflowLedger.on_message_received(state, "step_a", decorated, "2026-06-02T16:00:00.000Z")

    assert started.type == :workflow_step_attempt_started
    assert started.step == "step_a"
    assert get_in(state, ["steps", "step_a", "status"]) == "running"
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1

    assert get_in(state, ["steps", "step_a", "current_attempt", "attempt_id"]) ==
             "step_a:attempt:1"

    first_delivery = get_in(state, ["steps", "step_a", "last_message"])

    {state, events, actions} = reconcile(state, "2026-06-02T16:00:02.000Z")

    assert Enum.any?(events, &(&1.type == :workflow_step_attempt_timed_out))
    assert Enum.any?(events, &(&1.type == :workflow_step_attempt_retry_scheduled))
    assert {:terminate_agent, "step_a", _reason} = List.first(actions)
    assert get_in(state, ["steps", "step_a", "status"]) == "retry_wait"

    {state, [], [{:redeliver, "step_a", "step_a", retry_message}]} =
      reconcile(state, "2026-06-02T16:00:04.000Z")

    refute Message.id(retry_message) == Message.id(decorated)

    assert MirrorNeuron.Runtime.WorkflowMessage.invocation_key(first_delivery) ==
             MirrorNeuron.Runtime.WorkflowMessage.invocation_key(retry_message)

    assert retry_message["headers"]["mn.workflow.attempt_id"] == "step_a:attempt:2"
    assert retry_message["headers"]["mn.workflow.attempt"] == 2

    assert String.ends_with?(
             retry_message["headers"]["mn.workflow.idempotency_key"],
             ":step_a:2:#{Message.id(retry_message)}"
           )

    assert get_in(state, ["steps", "step_a", "status"]) == "queued"

    {state, [second_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        retry_message,
        "2026-06-02T16:00:04.100Z"
      )

    assert second_started.attempt == 2
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 2

    assert get_in(state, ["steps", "step_a", "current_attempt", "idempotency_key"]) ==
             retry_message["headers"]["mn.workflow.idempotency_key"]

    {state, events, actions} = reconcile(state, "2026-06-02T16:00:06.000Z")

    failed_event = Enum.find(events, &(&1.type == :workflow_step_failed))
    assert failed_event
    assert failed_event["error"]["schema_version"] == "mn.error.v1"
    assert failed_event["error"]["details"]["step_id"] == "step_a"
    assert {:fail_job, "step_a", _reason} = List.last(actions)
    assert get_in(state, ["steps", "step_a", "status"]) == "failed"
    assert get_in(state, ["steps", "step_a", "terminal_error", "schema_version"]) == "mn.error.v1"
  end

  test "marks an enqueue failure terminal instead of leaving the workflow queued" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "start"})

    {state, events} =
      WorkflowLedger.mark_delivery_failed(
        state,
        message,
        "step_a",
        {:message_id_conflict, Message.id(message), "acked"},
        "2026-06-02T16:00:00.000Z"
      )

    assert Enum.map(events, & &1.type) == [
             :workflow_message_dead_lettered,
             :workflow_step_failed
           ]

    assert get_in(state, ["steps", "step_a", "status"]) == "failed"
    assert get_in(state, ["steps", "step_a", "ended_at"]) == "2026-06-02T16:00:00.000Z"
    assert get_in(state, ["messages", Message.id(message), "status"]) == "failed"
  end

  test "resolves optional steps as partial after retry exhaustion" do
    {state, []} =
      WorkflowLedger.new(manifest(required?: false), runtime_nodes())
      |> WorkflowLedger.job_running()

    message = Message.new("job-1", "runtime", "step_a", "init", %{})

    {state, [_started]} =
      state
      |> WorkflowLedger.decorate_message("step_a", message)
      |> then(
        &WorkflowLedger.on_message_received(state, "step_a", &1, "2026-06-02T16:00:00.000Z")
      )

    {state, events, actions} = reconcile(state, "2026-06-02T16:00:02.000Z")

    assert actions == [{:terminate_agent, "step_a", "workflow step heartbeat deadline exceeded"}]
    assert Enum.any?(events, &(&1.type == :workflow_step_partial))
    assert get_in(state, ["steps", "step_a", "status"]) == "partial"
  end

  test "pause emits blocked events and resume preserves active attempt state" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "start"})
    decorated = WorkflowLedger.decorate_message(state, "step_a", message)

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        decorated,
        "2026-06-02T16:00:00.000Z"
      )

    {paused, [blocked]} = WorkflowLedger.pause(state, "2026-06-02T16:00:01.000Z")

    assert paused["status"] == "paused"
    assert blocked.type == :workflow_step_blocked
    assert blocked.step == "step_a"
    assert blocked["reason"] == "job paused"
    assert blocked["blocked_at"] == "2026-06-02T16:00:01.000Z"
    assert get_in(paused, ["steps", "step_a", "status"]) == "running"

    {resumed, []} = WorkflowLedger.resume(paused, "2026-06-02T16:00:02.000Z")

    assert resumed["status"] == "running"

    assert get_in(resumed, ["steps", "step_a", "current_attempt", "attempt_id"]) ==
             "step_a:attempt:1"

    assert get_in(resumed, ["steps", "step_a", "attempt_count"]) == 1
  end
end
