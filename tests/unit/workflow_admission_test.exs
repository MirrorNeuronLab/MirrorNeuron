defmodule MirrorNeuron.Runtime.WorkflowAdmissionTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.{Manifest, Message}
  alias MirrorNeuron.Builtins.StepSource
  alias MirrorNeuron.Runtime.{WorkflowAdmission, WorkflowLedger}

  test "a generated source collects every upstream delivery in one ledger attempt" do
    definition = %Manifest{
      flow: %{
        "steps" => [
          %{"id" => "left", "run" => "left"},
          %{"id" => "right", "run" => "right"},
          %{"id" => "publish", "run" => "publish__start"}
        ],
        "graph" => %{
          "edges" => [
            %{"from" => "left", "to" => "publish"},
            %{"from" => "right", "to" => "publish"}
          ]
        }
      }
    }

    source = %{
      node_id: "publish__start",
      agent_type: "step_source",
      config: %{
        "step_id" => "publish",
        "required_upstreams" => ["left", "right"],
        "fields" => %{
          "left" => %{"$ref" => "upstream", "step_id" => "left", "path" => ["value"]},
          "right" => %{"$ref" => "upstream", "step_id" => "right", "path" => ["value"]}
        },
        "output_message_type" => "publish_started"
      }
    }

    nodes = [source | Enum.map(~w(left right), &%{node_id: &1, config: %{}})]
    {ledger, []} = WorkflowLedger.new(definition, nodes) |> WorkflowLedger.job_running()
    left = boundary("left")
    right = boundary("right")

    {{:defer, :workflow_dependencies_pending}, ledger, [_]} =
      WorkflowAdmission.admit(ledger, source.node_id, left)

    ledger = Enum.reduce(~w(left right), ledger, &complete(&2, &1))

    {{:ok, admitted_right}, ledger, [_]} =
      WorkflowAdmission.admit(ledger, source.node_id, right)

    {:ok, state} = StepSource.init(source)

    {:ok, state, [{:event, :step_source_waiting, _}]} =
      StepSource.handle_message(admitted_right, state, %{})

    # Reconnect/recovery must retain the source boundary's admission contract.
    ledger = Jason.decode!(Jason.encode!(ledger))

    {{:ok, admitted_left}, ledger, []} =
      WorkflowAdmission.admit(ledger, source.node_id, left)

    assert Message.id(admitted_left) == Message.id(left)

    for key <- ~w(attempt_id idempotency_key deadline_at) do
      assert Message.headers(admitted_left)["mn.workflow." <> key] ==
               Message.headers(admitted_right)["mn.workflow." <> key]
    end

    assert Message.headers(admitted_left)["mn.workflow.source_step_id"] == "left"
    assert Message.headers(admitted_right)["mn.workflow.source_step_id"] == "right"
    assert ledger["steps"]["publish"]["attempt_count"] == 1
    assert ledger["messages"][Message.id(left)]["status"] == "running"
    assert ledger["messages"][Message.id(right)]["status"] == "running"

    {:ok, state, actions} = StepSource.handle_message(admitted_left, state, %{})
    {:emit, "publish_started", output, _} = Enum.find(actions, &match?({:emit, _, _, _}, &1))
    assert output["outputs"] == %{"left" => "left result", "right" => "right result"}

    {{:ok, replay}, _, []} = WorkflowAdmission.admit(ledger, source.node_id, right)
    assert Message.headers(replay) == Message.headers(admitted_right)

    assert {:ok, _, [{:event, :step_source_duplicate_ignored, _}]} =
             StepSource.handle_message(replay, state, %{})
  end

  test "child planner admission uses its instance rather than the absent template step" do
    definition = %Manifest{
      flow: %{
        "steps" => [
          %{"id" => "inspect", "run" => "inspect"},
          %{"id" => "report", "run" => "report"}
        ],
        "graph" => %{"edges" => [%{"from" => "inspect", "to" => "report"}]},
        "child_workflows" => %{
          "inspect" => %{
            "planner" => "planner",
            "templates" => %{"planner" => %{"run" => "planner"}},
            "inputs" => %{"context" => ["outputs", "context"]},
            "outputs" => %{"result" => []},
            "max_rounds" => 2,
            "max_steps_per_round" => 2
          }
        }
      }
    }

    nodes = Enum.map(~w(inspect planner report), &%{node_id: &1, config: %{}})
    {ledger, []} = WorkflowLedger.new(definition, nodes) |> WorkflowLedger.job_running()
    input = Message.new("job", "runtime", "inspect", "start", %{})
    {{:ok, _}, ledger, [_]} = WorkflowAdmission.admit(ledger, "inspect", input)

    {ledger, _, [{:redeliver, "inspect:p0", "planner", message}]} =
      WorkflowLedger.on_agent_event(ledger, "inspect", :workflow_step_attempt_completed, %{
        "outputs" => %{"context" => %{}}
      })

    preliminary =
      Message.new("job", "inspect", "report", "done", %{"outputs" => %{"context" => %{}}})

    assert {:skip, ^ledger, []} = WorkflowAdmission.admit(ledger, "report", preliminary)

    refute Map.has_key?(ledger["steps"], "planner")
    {{:ok, admitted}, ledger, [_]} = WorkflowAdmission.admit(ledger, "planner", message)
    assert Message.headers(admitted)["mn.workflow.step_id"] == "inspect:p0"
    assert Message.headers(admitted)["mn.workflow.template_id"] == "planner"
    assert Message.headers(admitted)["mn.workflow.attempt_id"] == "inspect:p0:attempt:1"
    assert is_binary(Message.headers(admitted)["mn.workflow.idempotency_key"])

    {{:ok, replay}, _, []} = WorkflowAdmission.admit(ledger, "planner", message)
    assert Message.headers(replay) == Message.headers(admitted)

    {ledger, _, [{:redeliver, "report", "report", final_message}]} =
      WorkflowLedger.on_agent_event(ledger, "planner", :workflow_step_attempt_completed, %{
        "step_id" => "inspect:p0",
        "outputs" => %{
          "child_plan" => %{
            "decision" => "stop",
            "revision" => 0,
            "reason" => "Complete",
            "output" => %{"answer" => "Final child result"}
          }
        }
      })

    assert {:skip, ^ledger, []} = WorkflowAdmission.admit(ledger, "report", preliminary)
    assert {{:ok, _}, _, [_]} = WorkflowAdmission.admit(ledger, "report", final_message)
    assert Message.from(final_message) == "workflow_ledger"
    [parent] = Message.body(final_message)["parents"]
    assert parent["output"]["outputs"]["result"] == %{"answer" => "Final child result"}
  end

  defp boundary(step_id) do
    Message.new(
      "job",
      step_id,
      "publish__start",
      "done",
      %{"step_id" => step_id, "outputs" => %{"value" => "#{step_id} result"}},
      headers: %{"mn.workflow.source_step_id" => step_id}
    )
  end

  defp complete(ledger, step_id) do
    {ledger, _, _} =
      WorkflowLedger.on_agent_event(ledger, step_id, :workflow_step_attempt_completed, %{})

    ledger
  end
end
