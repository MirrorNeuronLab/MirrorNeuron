defmodule MirrorNeuron.Runtime.EventEnvelopeTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.EventEnvelope

  test "publication adds canonical fields without changing routing payload" do
    payload = %{
      message: "Person presence confirmed",
      owner_blueprint: "cctv_operator",
      step: "detect",
      worker: "detector",
      activity_kind: "finding"
    }

    event = EventEnvelope.normalize(%{type: :agent_activity, payload: payload}, "job-1")
    assert event.schema == "mn.runtime.event.v1"
    assert event.level == "info"
    assert event.owner_blueprint == "cctv_operator"
    assert event.step_id == "detect"
    assert event.agent_id == "detector"
    assert event.activity_kind == "finding"
    assert event.payload == payload
    assert {:ok, _, _} = DateTime.from_iso8601(event.timestamp)
    assert EventEnvelope.normalize(event, "job-1") == event
  end

  test "worker receipt metadata survives Core publication" do
    event =
      EventEnvelope.normalize(
        %{
          "type" => "agent_activity",
          "payload" => %{
            "event_id" => "receipt-1",
            "timestamp" => "2026-10-13T15:00:00Z",
            "level" => "warning",
            "owner_blueprint" => "research_assistant"
          }
        },
        "job-2"
      )

    assert event["event_id"] == "receipt-1"
    assert event["timestamp"] == "2026-10-13T15:00:00Z"
    assert event["level"] == "warning"
    assert event["owner_blueprint"] == "research_assistant"
    refute Map.has_key?(event, :job_id)
  end

  test "infrastructure failures and retries have meaningful levels" do
    assert EventEnvelope.normalize(%{type: :worker_failed}, "job").level == "error"
    assert EventEnvelope.normalize(%{type: :retry_scheduled}, "job").level == "warning"
    assert EventEnvelope.normalize(%{type: :command_started}, "job").activity_kind == "action"
  end

  test "malformed worker levels do not crash publication" do
    event =
      EventEnvelope.normalize(
        %{"type" => "agent_activity", "payload" => %{"level" => %{}}},
        "job"
      )

    assert event["level"] == "info"
    assert event["payload"]["level"] == %{}
  end
end
