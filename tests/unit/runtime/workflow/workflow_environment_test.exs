defmodule MirrorNeuron.Runner.WorkflowEnvironmentTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.WorkflowEnvironment

  test "physical run headers override the definition label in runner environment" do
    env =
      WorkflowEnvironment.from_options(
        run_id: "fallback",
        message:
          MirrorNeuron.Message.new("job", "source", "target", "input", %{},
            headers: %{
              "mn.workflow.run_id" => "physical-runtime-id",
              "mn.workflow.step_id" => "parent:r1:task1",
              "mn.workflow.attempt" => 2,
              "mn.workflow.deadline_at" => "2026-10-22T17:00:00Z",
              "mn.workflow.heartbeat_deadline_at" => "2026-10-22T17:01:00Z"
            }
          )
      )

    merged = Map.merge(%{"MN_WORKFLOW_RUN_ID" => "cli-label"}, env)
    assert merged["MN_WORKFLOW_RUN_ID"] == "physical-runtime-id"
    assert merged["MN_WORKFLOW_STEP_ID"] == "parent:r1:task1"
    assert merged["MN_WORKFLOW_ATTEMPT"] == "2"
    assert merged["MN_WORKFLOW_DEADLINE_AT"] == "2026-10-22T17:00:00Z"
    assert merged["MN_WORKFLOW_HEARTBEAT_DEADLINE_AT"] == "2026-10-22T17:01:00Z"
    assert merged["MN_BLOCK_EVENT_PROTOCOL"] == "mn.block_events/v1"
    assert merged["MN_BLOCK_EVENT_PUBLICATION_PROTOCOL"] == "mn.published_files/v1"
  end
end
