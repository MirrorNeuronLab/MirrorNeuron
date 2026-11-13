defmodule MirrorNeuron.Runtime.WorkflowLedger.DefinitionsTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Manifest

  alias MirrorNeuron.Runtime.WorkflowLedger

  test "explicit runner bindings and compiled scalar targets select the same executor" do
    original = manifest()

    for run <- ["step_a", %{"agent" => "step_a", "binding" => "worker"}] do
      step = %{"id" => "logical_step", "run" => run}
      ledger = WorkflowLedger.new(%{original | flow: %{"steps" => [step]}}, runtime_nodes())
      assert get_in(ledger, ["steps", "logical_step", "agent_ids"]) == ["step_a"]
      assert get_in(ledger, ["steps", "logical_step", "run"]) == "step_a"
    end
  end

  test "binds a workflow step to its explicitly named runtime agent" do
    manifest = %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "prepare",
            "run" => "prepare_voice_service",
            "agent_id" => "ingress",
            "control" => %{"required" => true, "retry" => %{"max_attempts" => 1}}
          }
        ],
        "graph" => %{"edges" => []}
      }
    }

    {state, []} =
      WorkflowLedger.new(manifest, [%{node_id: "ingress", config: %{}}])
      |> WorkflowLedger.job_running()

    assert WorkflowLedger.agent_to_step(state) == %{"ingress" => "prepare"}
  end

  test "binds every compiled crew invocation to its logical workflow step" do
    manifest = %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "prepare",
            "run" => "prepare",
            "agent_id" => "prepare",
            "agent_ids" => ["prepare", "prepare__extractor", "prepare__normalizer"],
            "control" => %{"required" => true, "retry" => %{"max_attempts" => 1}}
          }
        ],
        "graph" => %{"edges" => []}
      }
    }

    nodes =
      Enum.map(["prepare", "prepare__extractor", "prepare__normalizer"], fn node_id ->
        %{node_id: node_id, config: %{}}
      end)

    {state, []} = WorkflowLedger.new(manifest, nodes) |> WorkflowLedger.job_running()

    assert WorkflowLedger.agent_to_step(state) == %{
             "prepare" => "prepare",
             "prepare__extractor" => "prepare",
             "prepare__normalizer" => "prepare"
           }
  end
end
