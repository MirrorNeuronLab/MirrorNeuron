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
              "mn.workflow.attempt" => 2
            }
          )
      )

    merged = Map.merge(%{"MN_WORKFLOW_RUN_ID" => "cli-label"}, env)
    assert merged["MN_WORKFLOW_RUN_ID"] == "physical-runtime-id"
    assert merged["MN_WORKFLOW_STEP_ID"] == "parent:r1:task1"
    assert merged["MN_WORKFLOW_ATTEMPT"] == "2"
  end
end
