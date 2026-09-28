defmodule MirrorNeuron.Runtime.WorkflowPauseTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.WorkflowLedger

  test "long pauses freeze parent, dynamic child, beacon and retry clocks without replaying attempts" do
    step = %{
      "status" => "running",
      "deadline_at" => "2026-06-02T16:00:10.000Z",
      "heartbeat_deadline_at" => "2026-06-02T16:00:05.000Z",
      "current_attempt" => %{
        "attempt_id" => "child:attempt:1",
        "deadline_at" => "2026-06-02T16:00:10.000Z"
      }
    }

    state = %{
      "enabled" => true,
      "status" => "running",
      "steps" => %{
        "investigation" => Map.put(step, "heartbeat_deadline_at", nil),
        "child" => Map.put(step, "dynamic_instance", true),
        "retry" =>
          Map.merge(step, %{"status" => "retry_wait", "retry_at" => "2026-06-02T16:00:04.000Z"}),
        "done" => Map.put(step, "status", "completed")
      }
    }

    {paused, _} = WorkflowLedger.pause(state, "2026-06-02T16:00:01.000Z")
    {paused, _} = WorkflowLedger.pause(paused, "2026-06-02T17:00:00.000Z")
    {resumed, []} = WorkflowLedger.resume(paused, "2026-06-02T18:00:01.000Z")

    assert resumed["steps"]["investigation"]["deadline_at"] == "2026-06-02T18:00:10.000Z"
    assert resumed["steps"]["investigation"]["heartbeat_deadline_at"] == nil
    assert resumed["steps"]["child"]["heartbeat_deadline_at"] == "2026-06-02T18:00:05.000Z"

    assert resumed["steps"]["child"]["current_attempt"] == %{
             "attempt_id" => "child:attempt:1",
             "deadline_at" => "2026-06-02T18:00:10.000Z"
           }

    assert resumed["steps"]["retry"]["retry_at"] == "2026-06-02T18:00:04.000Z"
    assert resumed["steps"]["done"] == state["steps"]["done"]
    refute Map.has_key?(resumed, "paused_at")
    assert {^resumed, []} = WorkflowLedger.resume(resumed, "2026-06-02T18:00:01.000Z")
  end
end
