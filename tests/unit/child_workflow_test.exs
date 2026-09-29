defmodule MirrorNeuron.Runtime.ChildWorkflowTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.{Manifest, Message}
  alias MirrorNeuron.Runtime.{WorkflowLedger, ChildWorkflow}

  defp manifest do
    %Manifest{
      flow: %{
        "steps" => [
          %{"id" => "inspect", "run" => "inspect"},
          %{"id" => "report", "run" => "report"}
        ],
        "graph" => %{"edges" => [%{"id" => "exit", "from" => "inspect", "to" => "report"}]},
        "child_workflows" => %{
          "inspect" => %{
            "planner" => "planner",
            "templates" => %{"planner" => %{"run" => "planner"}, "query" => %{"run" => "query"}},
            "inputs" => %{"context" => ["outputs", "context"]},
            "outputs" => %{"result" => []},
            "max_rounds" => 3,
            "max_steps_per_round" => 4
          }
        }
      }
    }
  end

  defp nodes, do: Enum.map(~w(inspect report planner query), &%{node_id: &1, config: %{}})

  defp started(definition \\ manifest()) do
    {state, []} = WorkflowLedger.new(definition, nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job", "runtime", "inspect", "start", %{})
    {state, _} = WorkflowLedger.on_message_received(state, "inspect", message)

    {state, _, actions} =
      WorkflowLedger.on_agent_event(state, "inspect", "workflow_step_attempt_completed", %{
        "outputs" => %{"context" => %{"path" => "context.json"}}
      })

    {state, actions}
  end

  defp finish(state, actions, output) do
    {:redeliver, id, agent, message} = Enum.find(actions, &match?({:redeliver, _, _, _}, &1))
    {state, _} = WorkflowLedger.on_message_received(state, agent, message)

    WorkflowLedger.on_agent_event(state, agent, "workflow_step_attempt_completed", %{
      "step_id" => id,
      "outputs" => output
    })
  end

  defp plan(
         revision,
         steps \\ [%{"id" => "read", "template" => "query", "needs" => [], "input" => %{}}]
       ) do
    %{
      "child_plan" => %{
        "decision" => "execute",
        "revision" => revision,
        "steps" => steps,
        "rationale" => "test newly found evidence",
        "evidence_refs" => []
      }
    }
  end

  test "child task labels survive scheduling, topology events and recovery" do
    {state, actions} = started()

    output =
      plan(0, [
        %{
          "id" => "read",
          "label" => "Scan source: src/api.py",
          "template" => "query",
          "needs" => [],
          "input" => %{}
        }
      ])

    {state, events, _actions} = finish(state, actions, output)
    assert state["steps"]["inspect:r1:read"]["label"] == "Scan source: src/api.py"
    delta = Enum.find(events, &(&1.type == :workflow_child_plan_committed)).topology_delta
    assert hd(delta.steps_added)["label"] == "Scan source: src/api.py"
    restored = WorkflowLedger.new(manifest(), nodes(), %{"workflow_state" => state})
    assert restored["steps"]["inspect:r1:read"]["label"] == "Scan source: src/api.py"
  end

  test "invalid child labels are rejected before dispatch" do
    for label <- [42, "", String.duplicate("x", 1025)] do
      {state, actions} = started()

      output =
        put_in(plan(0), ["child_plan", "steps"], [
          %{
            "id" => "read",
            "label" => label,
            "template" => "query",
            "needs" => [],
            "input" => %{}
          }
        ])

      {state, _events, actions} = finish(state, actions, output)
      assert state["steps"]["inspect"]["status"] == "failed"
      refute Enum.any?(actions, &match?({:redeliver, _, _, _}, &1))
    end
  end

  test "128 artifact-backed tasks fit the bounded coordination plan" do
    definition = manifest()

    definition = %{
      definition
      | flow: put_in(definition.flow, ["child_workflows", "inspect", "max_steps_per_round"], 128)
    }

    steps =
      Enum.map(1..128, fn n ->
        digest = String.duplicate("a", 64)

        %{
          "id" => "task-#{n}",
          "template" => "query",
          "needs" => if(n == 1, do: [], else: ["task-#{n - 1}"]),
          "input" => %{
            "review_input" => %{
              "type" => "artifact_ref",
              "version" => "mn.artifact_handoff/v1",
              "commit_id" => "input-#{digest}",
              "path" => "#{digest}.json",
              "sha256" => digest,
              "size_bytes" => 60000,
              "kind" => "review_input",
              "producer" => %{"run_id" => "test-run", "step_instance" => "owner-admission"}
            }
          }
        }
      end)

    output = plan(0, steps)
    assert byte_size(Jason.encode!(output["child_plan"])) > 32768
    {state, actions} = started(definition)
    {state, events, actions} = finish(state, actions, output)
    assert state["child_workflows"]["inspect"]["phase"] == "executing"
    assert length(state["child_workflows"]["inspect"]["active"]) == 128
    assert Enum.any?(events, &(&1.type == :workflow_child_plan_committed))
    delta = Enum.find(events, &(&1.type == :workflow_child_plan_committed)).topology_delta
    assert length(delta.steps_added) > 0
    assert Enum.all?(delta.steps_added, &(&1["parent_step_id"] == "inspect"))
    assert Enum.all?(delta.steps_added, &(not Map.has_key?(&1, "instance_input")))
    assert Enum.all?(delta.steps_added, &(not Map.has_key?(&1, "output")))
    assert length(actions) == 1
    restored = WorkflowLedger.new(definition, nodes(), %{"workflow_state" => state})
    assert restored["child_workflows"] == state["child_workflows"]
  end

  test "plan byte ceiling applies to execute and stop before dispatch" do
    for output <- [
          put_in(plan(0), ["child_plan", "rationale"], String.duplicate("界", 45000)),
          %{
            "child_plan" => %{
              "decision" => "stop",
              "revision" => 0,
              "reason" => "complete",
              "output" => %{"blob" => String.duplicate("x", 131_072)}
            }
          }
        ] do
      {state, actions} = started()
      {state, events, actions} = finish(state, actions, output)
      assert state["steps"]["inspect"]["status"] == "failed"
      assert state["child_workflows"]["inspect"]["plans"] == []
      refute Enum.any?(actions, &match?({:redeliver, _, _, _}, &1))

      assert Enum.any?(
               events,
               &(&1.type == :workflow_child_failed and String.contains?(&1.reason, "128 KiB"))
             )
    end
  end

  test "Docker child templates use task deadlines instead of unstreamed node beacons" do
    definition = manifest()

    flow =
      put_in(definition.flow, ["child_workflows", "inspect", "templates", "query", "control"], %{
        "timeout_seconds" => 300
      })

    runtime_nodes =
      Enum.map(nodes(), fn node ->
        %{
          node
          | config: %{
              "runner_module" => "MirrorNeuron.Runner.DockerWorker",
              "beacon_timeout_ms" => 45_000
            }
        }
      end)

    state = WorkflowLedger.new(%{definition | flow: flow}, runtime_nodes)
    assert state["child_templates"]["query"]["beacon_timeout_ms"] == 300_000

    flow =
      put_in(
        flow,
        ["child_workflows", "inspect", "templates", "query", "control", "beacon_timeout_ms"],
        90_000
      )

    state = WorkflowLedger.new(%{definition | flow: flow}, runtime_nodes)
    assert state["child_templates"]["query"]["beacon_timeout_ms"] == 90_000
  end

  test "OpenShell child templates use task deadlines instead of unstreamed node beacons" do
    definition = manifest()

    flow =
      put_in(definition.flow, ["child_workflows", "inspect", "templates", "query", "control"], %{
        "timeout_seconds" => 300
      })

    runtime_nodes =
      Enum.map(nodes(), fn node ->
        %{
          node
          | config: %{
              "runner_module" => "MirrorNeuron.Runner.OpenShell",
              "beacon_timeout_ms" => 45_000
            }
        }
      end)

    state = WorkflowLedger.new(%{definition | flow: flow}, runtime_nodes)
    assert state["child_templates"]["query"]["beacon_timeout_ms"] == 300_000

    flow =
      put_in(
        flow,
        ["child_workflows", "inspect", "templates", "query", "control", "beacon_timeout_ms"],
        90_000
      )

    state = WorkflowLedger.new(%{definition | flow: flow}, runtime_nodes)
    assert state["child_templates"]["query"]["beacon_timeout_ms"] == 90_000
  end

  test "parent waits, committed DAG executes, next planner sees results, then parent exits" do
    {state, actions} = started()
    assert state["steps"]["inspect"]["status"] == "running"
    assert state["steps"]["report"]["status"] == "pending"
    {state, events, actions} = finish(state, actions, plan(0))
    assert Enum.any?(events, &(&1.type == :workflow_child_plan_committed))
    delta = Enum.find(events, &(&1.type == :workflow_child_plan_committed)).topology_delta
    assert length(delta.steps_added) > 0
    assert Enum.all?(delta.steps_added, &(&1["parent_step_id"] == "inspect"))
    assert Enum.all?(delta.steps_added, &(not Map.has_key?(&1, "instance_input")))
    assert Enum.all?(delta.steps_added, &(not Map.has_key?(&1, "output")))
    assert state["child_workflows"]["inspect"]["phase"] == "executing"
    assert length(actions) == 1

    {state, _, actions} =
      finish(state, actions, %{"observation" => %{"path" => "new-counter-evidence.json"}})

    assert state["child_workflows"]["inspect"]["phase"] == "planning"
    assert length(state["child_workflows"]["inspect"]["results"]) == 1

    {state, _, actions} =
      finish(
        state,
        actions,
        plan(1, [
          %{
            "id" => "counter",
            "template" => "query",
            "needs" => [],
            "input" => %{"purpose" => "counter"}
          }
        ])
      )

    {state, _, actions} = finish(state, actions, %{"observation" => %{"path" => "counter.json"}})

    {state, events, actions} =
      finish(state, actions, %{
        "child_plan" => %{
          "decision" => "stop",
          "revision" => 2,
          "reason" => "resolved",
          "output" => %{"report" => "report.json"}
        }
      })

    assert state["steps"]["inspect"]["status"] == "completed"

    assert state["steps"]["inspect"]["output"]["outputs"]["result"] == %{
             "report" => "report.json"
           }

    assert Enum.any?(events, &(&1.type == :workflow_child_completed))
    assert [{:redeliver, "report", "report", _}] = actions
  end

  test "committed child state survives restoration without replanning" do
    {state, actions} = started()
    {state, _, _} = finish(state, actions, plan(0))
    restored = WorkflowLedger.new(manifest(), nodes(), %{"workflow_state" => state})
    assert restored["child_workflows"] == state["child_workflows"]
    assert restored["steps"]["inspect:r1:read"] == state["steps"]["inspect:r1:read"]
    assert restored["child_workflows"]["inspect"]["revision"] == 1
  end

  test "pausing a committed investigation preserves its child plan and timeout budget" do
    {state, actions} = started()
    {state, _, actions} = finish(state, actions, plan(0))
    {:redeliver, child, agent, message} = hd(actions)

    {state, _} =
      WorkflowLedger.on_message_received(state, agent, message, "2026-06-02T16:00:00.000Z")

    {paused, _} = WorkflowLedger.pause(state, "2026-06-02T16:00:01.000Z")
    restored = WorkflowLedger.new(manifest(), nodes(), %{"workflow_state" => paused})
    assert restored["paused_at"] == paused["paused_at"]
    {resumed, []} = WorkflowLedger.resume(restored, "2026-06-02T18:00:01.000Z")
    assert resumed["child_workflows"] == state["child_workflows"]

    assert resumed["steps"][child]["current_attempt"]["attempt_id"] ==
             state["steps"][child]["current_attempt"]["attempt_id"]

    {checked, _, actions} = WorkflowLedger.reconcile(resumed, "2026-06-02T18:00:02.000Z")
    assert checked["steps"][child]["status"] == "running"
    refute Enum.any?(actions, &match?({:terminate_agent, _, _}, &1))
  end

  test "cycles and unadmitted templates never dispatch" do
    for steps <- [
          [%{"id" => "a", "template" => "query", "needs" => ["a"], "input" => %{}}],
          [%{"id" => "a", "template" => "shell", "needs" => [], "input" => %{}}]
        ] do
      {state, actions} = started()
      {state, events, actions} = finish(state, actions, plan(0, steps))
      assert state["steps"]["inspect"]["status"] == "failed"
      refute Enum.any?(actions, &match?({:redeliver, _, _, _}, &1))
      assert Enum.any?(events, &(&1.type == :workflow_child_failed))
      assert state["child_workflows"]["inspect"]["plans"] == []
    end
  end

  test "partial execution resumes the committed DAG without a planner between tasks" do
    {state, actions} = started()

    graph = [
      %{"id" => "first", "template" => "query", "needs" => [], "input" => %{}},
      %{"id" => "second", "template" => "query", "needs" => ["first"], "input" => %{}}
    ]

    {state, _, actions} = finish(state, actions, plan(0, graph))
    {state, _, actions} = finish(state, actions, %{"observation" => "first result"})
    assert state["child_workflows"]["inspect"]["phase"] == "executing"
    refute Map.has_key?(state["steps"], "inspect:p1")
    restored = WorkflowLedger.new(manifest(), nodes(), %{"workflow_state" => state})
    assert restored["steps"]["inspect:r1:first"]["status"] == "completed"
    assert restored["child_workflows"] == state["child_workflows"]
    {restored, _, _} = finish(restored, actions, %{"observation" => "second result"})
    assert restored["child_workflows"]["inspect"]["phase"] == "planning"
    assert length(restored["child_workflows"]["inspect"]["results"]) == 2
  end

  test "duplicate planner completion cannot revise executing work" do
    {state, actions} = started()
    {state, _, _} = finish(state, actions, plan(0))

    {again, _, actions} =
      WorkflowLedger.on_agent_event(state, "planner", "workflow_step_attempt_completed", %{
        "step_id" => "inspect:p0",
        "outputs" => plan(0)
      })

    assert again["child_workflows"] == state["child_workflows"]
    assert actions == []
  end

  test "stale plan fails and separate runs do not share state" do
    {a, actions} = started()
    {b, _} = started()
    {a, _, _} = finish(a, actions, plan(2))
    assert a["child_workflows"]["inspect"]["phase"] == "failed"
    assert b["child_workflows"]["inspect"]["phase"] == "planning"
  end

  test "valid declarations require a pre-admitted planner" do
    assert ChildWorkflow.validation_errors(manifest().flow, ~w(inspect report planner query)) ==
             []

    assert [_] = ChildWorkflow.validation_errors(manifest().flow, ~w(inspect report query))
  end

  test "cancelled workflow cannot accept a planner result" do
    {state, actions} = started()
    {:redeliver, id, agent, message} = hd(actions)
    {state, _} = WorkflowLedger.on_message_received(state, agent, message)
    state = WorkflowLedger.finish(state, "cancelled")

    {same, [], []} =
      WorkflowLedger.on_agent_event(state, agent, "workflow_step_attempt_completed", %{
        "step_id" => id,
        "outputs" => plan(0)
      })

    assert same == state
  end

  test "compact progress does not expose child plans or mapped inputs" do
    {state, actions} = started()
    {state, _, _} = finish(state, actions, plan(0))
    compact = WorkflowLedger.compact_snapshot(state)
    assert compact["child_workflows"]["inspect"]["phase"] == "executing"
    refute Map.has_key?(compact, "child_definitions")
    refute Map.has_key?(compact["child_workflows"]["inspect"], "plans")
    refute Map.has_key?(compact["child_workflows"]["inspect"], "input")
  end

  test "mapped context cannot be replaced by task arguments" do
    {state, actions} = started()

    bad = [
      %{
        "id" => "read",
        "template" => "query",
        "needs" => [],
        "input" => %{"context" => %{"path" => "other-job"}}
      }
    ]

    {state, _, actions} = finish(state, actions, plan(0, bad))
    assert state["steps"]["inspect"]["status"] == "failed"
    assert Enum.any?(actions, &match?({:fail_job, "inspect", _}, &1))
  end

  test "round bound rejects another round but still admits a stop decision" do
    {state, actions} = started()
    state = put_in(state, ["child_workflows", "inspect", "round"], 3)
    {state, _, actions} = finish(state, actions, plan(0))
    assert state["steps"]["inspect"]["status"] == "failed"
    assert Enum.any?(actions, &match?({:fail_job, "inspect", _}, &1))
  end
end
