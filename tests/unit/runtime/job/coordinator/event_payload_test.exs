defmodule MirrorNeuron.Runtime.JobCoordinator.EventPayloadTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.JobCoordinator.Workflow

  test "graph patch events expose only the patch identity and revision" do
    payload = %{
      "patch_id" => "patch-a",
      "region_id" => "region-a",
      "base_revision" => 2,
      "operations" => [%{"private" => "configuration"}]
    }

    for type <- [:workflow_graph_patch, "workflow_graph_patch"] do
      assert Workflow.public_agent_event_payload(type, payload) ==
               Map.drop(payload, ["operations"])
    end
  end

  test "nested child plans in maps and lists are removed from public completion events" do
    for plan <- [%{"child_plan" => %{"secret" => "value"}}, %{child_plan: %{secret: "value"}}] do
      payload = %{
        "step_id" => "step-a",
        "attempt_id" => "attempt-a",
        "status" => "completed",
        "result" => [%{"nested" => [plan]}]
      }

      for type <- [:workflow_step_completed, "workflow_step_attempt_completed"] do
        assert Workflow.public_agent_event_payload(type, payload) == Map.drop(payload, ["result"])
      end
    end
  end

  test "completion payloads without a child plan remain intact" do
    payload = %{"step_id" => "step-a", "result" => [%{"value" => 42}]}
    assert Workflow.public_agent_event_payload(:workflow_step_completed, payload) == payload
  end
end
