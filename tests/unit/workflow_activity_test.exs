defmodule MirrorNeuron.Runtime.WorkflowActivityTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.{Manifest, Message}
  alias MirrorNeuron.Runtime.WorkflowLedger

  test "healthy progress can outlive former phase limits and only a completion receipt finishes it" do
    state = started()
    assert state["steps"]["a"]["deadline_at"] == nil

    state =
      Enum.reduce(1..120, state, fn number, state ->
        state = beacon(state, number * 30, number)
        {state, [], []} = WorkflowLedger.reconcile(state, at(number * 30))
        assert state["steps"]["a"]["status"] == "running"
        state
      end)

    {state, _, []} =
      WorkflowLedger.on_agent_event(state, "a", "workflow_step_completed", %{}, at(3601))

    assert state["steps"]["a"]["status"] == "completed"
    assert WorkflowLedger.completed?(state)

    {late, _, []} =
      WorkflowLedger.on_agent_event(state, "a", "agent_beacon", payload(999), at(9000))

    assert late["steps"]["a"]["status"] == "completed"
  end

  test "fresh process heartbeats and duplicate progress do not hide stalled work" do
    state = started() |> beacon(1, 1)
    deadline = state["steps"]["a"]["progress_deadline_at"]
    state = Enum.reduce(1..11, state, fn n, state -> beacon(state, n * 30, 1) end)
    assert state["steps"]["a"]["progress_deadline_at"] == deadline
    {state, _, actions} = WorkflowLedger.reconcile(state, at(330))
    assert state["steps"]["a"]["status"] == "failed"
    assert state["steps"]["a"]["terminal_error"]["code"] == "workflow.step.progress_timeout"
    assert Enum.any?(actions, &match?({:fail_job, "a", _}, &1))
  end

  test "runtime liveness cannot renew progress and missing heartbeats still fail" do
    state = started() |> beacon(1, 1)

    {state, _, []} =
      WorkflowLedger.on_agent_event(
        state,
        "a",
        "agent_beacon",
        Map.put(payload(999), "source", "runtime"),
        at(30)
      )

    assert state["steps"]["a"]["progress_sequences"]["a"]["sequence"] == 1
    {state, _, _} = WorkflowLedger.reconcile(state, at(76))
    assert state["steps"]["a"]["terminal_error"]["code"] == "workflow.step.heartbeat_timeout"
  end

  test "a bounded human wait survives inactivity, resumes, and cannot renew its expiry" do
    state = started()
    wait = %{"wait_id" => "review-1", "wait_timeout_ms" => 3_600_000}
    state = beacon(state, 1, 1, wait)
    deadline = state["steps"]["a"]["progress_deadline_at"]
    state = beacon(state, 1000, 2, wait)
    assert state["steps"]["a"]["progress_deadline_at"] == deadline
    {state, [], []} = WorkflowLedger.reconcile(state, at(1000))
    assert state["steps"]["a"]["work_state"] == "waiting"
    state = beacon(state, 1001, 3)
    assert state["steps"]["a"]["work_state"] == "active"
    {state, [], []} = WorkflowLedger.reconcile(state, at(1001))
    assert state["steps"]["a"]["status"] == "running"
  end

  test "recovery retains progress identity and pause excludes paused time" do
    state = started() |> beacon(1, 1)
    restored = state |> Jason.encode!() |> Jason.decode!()
    {paused, _} = WorkflowLedger.pause(restored, at(2))
    {resumed, _} = WorkflowLedger.resume(paused, at(3602))
    assert resumed["steps"]["a"]["progress_deadline_at"] == at(3901)
    resumed = beacon(resumed, 3603, 2)
    {resumed, [], []} = WorkflowLedger.reconcile(resumed, at(3603))
    assert resumed["steps"]["a"]["attempt_count"] == 1
  end

  test "repeated waiting heartbeats cannot hide an expired external wait" do
    wait = %{"wait_id" => "review-1", "wait_timeout_ms" => 3_600_000}
    state = started() |> beacon(1, 1, wait) |> beacon(4000, 2, wait)
    {state, _, _} = WorkflowLedger.reconcile(state, at(4000))
    assert state["steps"]["a"]["terminal_error"]["code"] == "workflow.step.progress_timeout"
  end

  test "activity supervision validates the physical progress transport" do
    alias MirrorNeuron.Runtime.WorkflowActivity
    flow = %{"execution" => %{"supervision" => "activity"}}

    host = %{
      agent_type: "executor",
      config: %{
        "runner_module" => "MirrorNeuron.Runner.HostLocal",
        "beacon_enabled" => true,
        "agent_beacon_required" => true
      }
    }

    assert WorkflowActivity.validation_errors(flow, [host]) == []
    buffered = put_in(host, [:config, "runner_module"], "MirrorNeuron.Runner.DockerWorker")
    assert [_] = WorkflowActivity.validation_errors(flow, [buffered])

    assert [_] =
             WorkflowActivity.validation_errors(
               put_in(flow, ["execution", "supervision"], "invalid"),
               [host]
             )
  end

  test "explicit execution budgets remain authoritative despite healthy progress" do
    state = started(%{"timeout_seconds" => 60}) |> beacon(59, 1) |> beacon(61, 2)
    {state, _, _} = WorkflowLedger.reconcile(state, at(61))
    assert state["steps"]["a"]["terminal_reason"] == "workflow step deadline exceeded"
  end

  defp started(control \\ %{}) do
    manifest = %Manifest{
      type: "batch",
      flow: %{
        "execution" => %{"supervision" => "activity"},
        "steps" => [%{"id" => "a", "run" => "a", "control" => control}]
      }
    }

    {state, []} =
      WorkflowLedger.new(manifest, [%{node_id: "a", config: %{}}])
      |> WorkflowLedger.job_running(at(0))

    {state, [_]} =
      WorkflowLedger.on_message_received(
        state,
        "a",
        Message.new("job", "runtime", "a", "init", %{}),
        at(0)
      )

    state
  end

  defp beacon(state, seconds, sequence, extra \\ %{}) do
    {state, _, []} =
      WorkflowLedger.on_agent_event(
        state,
        "a",
        "agent_beacon",
        Map.merge(payload(sequence), extra),
        at(seconds)
      )

    state
  end

  defp payload(sequence),
    do: %{"source" => "agent", "agent_id" => "a", "pid" => 7, "progress_sequence" => sequence}

  defp at(seconds),
    do: DateTime.add(~U[2026-10-23 12:00:00.000Z], seconds, :second) |> DateTime.to_iso8601()
end
