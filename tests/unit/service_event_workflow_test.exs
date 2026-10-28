defmodule MirrorNeuron.Runtime.ServiceEventWorkflowTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.{Manifest, Message}
  alias MirrorNeuron.Runner.WorkflowEnvironment
  alias MirrorNeuron.Runtime.{WorkflowAdmission, WorkflowLedger}

  test "native service phases accept successive scenes after earlier results complete" do
    {manifest, nodes} = event_service()
    ledger = WorkflowLedger.new(manifest, nodes)
    refute WorkflowLedger.enabled?(ledger)
    refute WorkflowLedger.completed?(ledger)
    physical_run = WorkflowLedger.run_id(ledger)
    assert is_binary(physical_run) and physical_run != ""
    assert WorkflowLedger.agent_to_step(ledger) == %{}

    for sequence <- 1..2, node <- nodes do
      state = %{
        node: node,
        coordinator: self(),
        runtime_context: %{workflow_agent_steps: WorkflowLedger.agent_to_step(ledger)}
      }

      message =
        Message.new("execution", "upstream", node.node_id, "scene", %{"sequence" => sequence})

      assert {:ok, ^message} = WorkflowAdmission.prepare(message, state)
      assert {^ledger, []} = WorkflowLedger.on_message_received(ledger, node.node_id, message)

      assert {^ledger, [], []} =
               WorkflowLedger.on_agent_event(
                 ledger,
                 node.node_id,
                 :workflow_step_attempt_completed,
                 %{"outputs" => %{"sequence" => sequence}}
               )

      env = WorkflowEnvironment.from_options(message: message, run_id: physical_run)
      assert env["MN_WORKFLOW_RUN_ID"] == physical_run
      refute Map.has_key?(env, "MN_WORKFLOW_DEADLINE_AT")
    end
  end

  test "absent dynamic configuration also retains event delivery" do
    {manifest, nodes} = event_service()
    flow = Map.delete(manifest.flow, "dynamic")
    refute WorkflowLedger.enabled?(WorkflowLedger.new(%{manifest | flow: flow}, nodes))
  end

  test "disabled dynamic configuration cannot hide template declarations" do
    {manifest, nodes} = event_service()
    flow = Map.put(manifest.flow, "dynamic", %{"enabled" => false, "templates" => %{}})
    assert WorkflowLedger.enabled?(WorkflowLedger.new(%{manifest | flow: flow}, nodes))
  end

  test "event service pause and resume retain the physical output identity" do
    {manifest, nodes} = event_service()
    ledger = WorkflowLedger.new(manifest, nodes)
    {paused, []} = WorkflowLedger.pause(ledger)
    {resumed, []} = WorkflowLedger.resume(Jason.decode!(Jason.encode!(paused)))
    assert WorkflowLedger.run_id(resumed) == WorkflowLedger.run_id(ledger)
    assert WorkflowLedger.new(manifest, nodes, %{"workflow_state" => resumed}) == ledger
  end

  test "ordinary batch event bindings retain one-shot DAG admission" do
    {manifest, nodes} = event_service()
    ledger = WorkflowLedger.new(%{manifest | type: "batch"}, nodes)
    assert WorkflowLedger.enabled?(ledger)
    first = Message.new("execution", "runtime", "sample", "scene", %{"sequence" => 1})
    {{:ok, _}, ledger, [_]} = WorkflowAdmission.admit(ledger, "sample", first)

    {ledger, _, _} =
      WorkflowLedger.on_agent_event(ledger, "sample", :workflow_step_attempt_completed, %{})

    second = Message.new("execution", "runtime", "sample", "scene", %{"sequence" => 2})
    assert {:skip, _, [_]} = WorkflowAdmission.admit(ledger, "sample", second)
  end

  test "mixed services and unbound workers do not disable finite DAG controls" do
    {manifest, [first | rest]} = event_service()
    ordinary = put_in(first.config, %{})
    assert WorkflowLedger.enabled?(WorkflowLedger.new(manifest, [ordinary | rest]))
    unknown = put_in(first.config["block_event"]["version"], "unknown")
    assert WorkflowLedger.enabled?(WorkflowLedger.new(manifest, [unknown | rest]))
  end

  test "native callbacks in dynamic and child DAGs retain ledger controls" do
    {manifest, nodes} = event_service()
    dynamic = Map.put(manifest.flow, "mode", "dynamic_dag")
    assert WorkflowLedger.enabled?(WorkflowLedger.new(%{manifest | flow: dynamic}, nodes))

    child = Map.put(manifest.flow, "child_workflows", %{"sample" => %{"templates" => %{}}})
    assert WorkflowLedger.enabled?(WorkflowLedger.new(%{manifest | flow: child}, nodes))
  end

  defp event_service do
    ids = ~w(sample understand report)
    steps = Enum.map(ids, &%{"id" => &1, "run" => &1})

    nodes =
      Enum.map(ids, fn id ->
        %{
          node_id: id,
          agent_type: "executor",
          config: %{
            "block_event" => %{
              "version" => "mn.block_events/v1",
              "ports" => %{},
              "event_types" => []
            },
            "timeout_seconds" => 60
          }
        }
      end)

    manifest = %Manifest{
      type: "service",
      flow: %{
        "steps" => steps,
        "dynamic" => %{"enabled" => false},
        "graph" => %{
          "edges" => [
            %{"from" => "sample", "to" => "understand"},
            %{"from" => "understand", "to" => "report"}
          ]
        }
      }
    }

    {manifest, nodes}
  end
end
