defmodule MirrorNeuron.Runtime.WorkflowLedger.FencingTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.WorkflowLedger
  alias MirrorNeuron.Runtime.WorkflowAdmission

  test "admission returns the ledger attempt to the handler and replay reuses it" do
    {ledger, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{})

    {{:ok, admitted}, ledger, [started]} = WorkflowAdmission.admit(ledger, "step_a", message)
    assert started.type == :workflow_step_attempt_started
    assert Message.id(admitted) == Message.id(message)
    key = Message.headers(admitted)["mn.workflow.idempotency_key"]
    assert is_binary(key) and key != ""
    assert Message.headers(admitted)["mn.workflow.attempt_id"] == "step_a:attempt:1"

    # A recovered delivery still contains the original, undecorated message.
    restored = Jason.decode!(Jason.encode!(ledger))
    {{:ok, replay}, restored, []} = WorkflowAdmission.admit(restored, "step_a", message)
    assert Message.headers(replay)["mn.workflow.idempotency_key"] == key
    assert restored["steps"]["step_a"]["attempt_count"] == 1

    now = DateTime.utc_now()
    {paused, _} = WorkflowLedger.pause(restored, DateTime.to_iso8601(now))

    {resumed, _} =
      WorkflowLedger.resume(paused, DateTime.to_iso8601(DateTime.add(now, 5, :second)))

    {{:ok, after_pause}, _, []} = WorkflowAdmission.admit(resumed, "step_a", message)
    assert Message.headers(after_pause) == Message.headers(admitted)
  end

  test "admission waits for dependencies and never borrows another message's attempt" do
    ledger = dag_state(["a", "b"], [edge("a", "b")])
    blocked = Message.new("job-1", "a", "b", "completed", %{})

    assert {{:defer, :workflow_dependencies_pending}, _, _} =
             WorkflowAdmission.admit(ledger, "b", blocked)

    message = Message.new("job-1", "runtime", "a", "init", %{})
    {{:ok, _}, ledger, [_]} = WorkflowAdmission.admit(ledger, "a", message)
    other = Message.new("job-1", "runtime", "a", "init", %{})

    assert {{:error, :missing_workflow_attempt_context}, _, _} =
             WorkflowAdmission.admit(ledger, "a", other)

    terminal = put_in(ledger, ["steps", "a", "status"], "completed")
    assert {:skip, _, _} = WorkflowAdmission.admit(terminal, "a", message)
  end

  test "a late specialist cannot open a retry or run under the next entrypoint's attempt" do
    now = "2026-06-02T16:00:00.000Z"
    {ledger, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    start = Message.new("job-1", "runtime", "step_a", "start", %{})
    {ledger, [_]} = WorkflowLedger.on_message_received(ledger, "step_a", start, now)
    first = ledger["steps"]["step_a"]["last_message"]

    late =
      Message.new("job-1", "specialist", "join", "result", %{}, headers: Message.headers(first))

    {ledger, _, _} = reconcile(ledger, "2026-06-02T16:00:03.000Z")
    assert ledger["steps"]["step_a"]["status"] == "retry_wait"

    assert {:skip, _, _} = WorkflowAdmission.admit(ledger, "join", late)
    {waiting, [ignored]} = WorkflowLedger.on_message_received(ledger, "join", late, now)
    assert ignored.type == :workflow_step_duplicate_message_ignored
    assert waiting["steps"]["step_a"]["current_attempt"] == nil

    {queued, _, [{:redeliver, "step_a", "step_a", retry}]} =
      reconcile(waiting, "2026-06-02T16:00:04.000Z")

    for state <- [
          queued,
          update_in(queued, ["steps", "step_a"], &Map.delete(&1, "retry_delivery_id"))
        ] do
      assert {:skip, _, _} = WorkflowAdmission.admit(state, "join", late)
      {state, [_]} = WorkflowLedger.on_message_received(state, "join", late, now)
      assert state["steps"]["step_a"]["status"] == "queued"
      assert {:skip, _, _} = WorkflowAdmission.admit(state, "step_a", start)
      assert {:skip, _, _} = WorkflowAdmission.admit(state, "join", retry)
      assert {{:ok, retry}, active, [started]} = WorkflowAdmission.admit(state, "step_a", retry)
      assert started.attempt == 2
      assert {:skip, _, _} = WorkflowAdmission.admit(active, "join", late)

      current =
        Message.new("job-1", "specialist", "join", "result", %{}, headers: Message.headers(retry))

      assert {{:ok, ^current}, ^active, []} = WorkflowAdmission.admit(active, "join", current)
    end
  end

  test "ignores additional messages while a step attempt is already running" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    first_message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})
    second_message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "second"})

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        WorkflowLedger.decorate_message(state, "step_a", first_message),
        "2026-06-02T16:00:00.000Z"
      )

    {state, [ignored]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        second_message,
        "2026-06-02T16:00:00.100Z"
      )

    assert ignored.type == :workflow_step_duplicate_message_ignored
    assert ignored["reason"] == "workflow step already running"
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1

    assert get_in(state, ["steps", "step_a", "current_attempt", "message_id"]) !=
             Message.id(second_message)
  end

  test "re-receiving the active message is idempotent" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})
    decorated = WorkflowLedger.decorate_message(state, "step_a", message)

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        decorated,
        "2026-06-02T16:00:00.000Z"
      )

    {state, []} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        decorated,
        "2026-06-02T16:00:00.100Z"
      )

    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1
    assert get_in(state, ["steps", "step_a", "status"]) == "running"
    assert get_in(state, ["messages", Message.id(decorated), "status"]) == "running"
  end

  test "ignores late messages after a step is completed" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        WorkflowLedger.decorate_message(state, "step_a", message),
        "2026-06-02T16:00:00.000Z"
      )

    {state, [_completed], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :workflow_step_attempt_completed,
        %{"status" => "completed"},
        "2026-06-02T16:00:01.000Z"
      )

    late_message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "late"})

    {state, [ignored]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        late_message,
        "2026-06-02T16:00:02.000Z"
      )

    assert ignored.type == :workflow_step_duplicate_message_ignored
    assert ignored["reason"] == "workflow step already terminal"
    assert get_in(state, ["steps", "step_a", "status"]) == "completed"
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1
  end

  test "ignores late agent events after a step is completed" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        WorkflowLedger.decorate_message(state, "step_a", message),
        "2026-06-02T16:00:00.000Z"
      )

    {state, [_completed], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :workflow_step_attempt_completed,
        %{"status" => "completed"},
        "2026-06-02T16:00:01.000Z"
      )

    {state, [ignored], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :agent_beacon,
        %{"status" => "working"},
        "2026-06-02T16:00:02.000Z"
      )

    assert ignored.type == :workflow_step_stale_event_ignored
    assert ignored["reason"] == "workflow step already terminal"
    assert get_in(state, ["steps", "step_a", "status"]) == "completed"
    refute get_in(state, ["steps", "step_a", "heartbeat_deadline_at"])
  end
end
