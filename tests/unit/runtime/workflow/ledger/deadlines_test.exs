defmodule MirrorNeuron.Runtime.WorkflowLedger.DeadlinesTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Manifest

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.WorkflowLedger

  test "uses the declared step timeout as the default workflow beacon deadline" do
    manifest = %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "slow_llm_step",
            "run" => "slow_llm_step",
            "control" => %{"timeout_seconds" => 300}
          }
        ],
        "graph" => %{"edges" => []}
      }
    }

    {state, []} =
      WorkflowLedger.new(manifest, [
        %{
          node_id: "slow_llm_step",
          config: %{
            "runner_module" => "MirrorNeuron.Runner.DockerWorker",
            "beacon_timeout_ms" => 45_000
          }
        }
      ])
      |> WorkflowLedger.job_running()

    assert get_in(state, ["steps", "slow_llm_step", "timeout_seconds"]) == 300
    assert get_in(state, ["steps", "slow_llm_step", "beacon_timeout_ms"]) == 300_000
    message = Message.new("job", "runtime", "slow_llm_step", "start", %{})

    {state, _} =
      WorkflowLedger.on_message_received(
        state,
        "slow_llm_step",
        message,
        "2026-06-02T16:00:00.000Z"
      )

    {state, [], []} = reconcile(state, "2026-06-02T16:01:00.000Z")
    assert state["steps"]["slow_llm_step"]["status"] == "running"
    {state, events, _} = reconcile(state, "2026-06-02T16:05:01.000Z")
    assert Enum.any?(events, &(&1.type == :workflow_step_attempt_timed_out))
    assert state["steps"]["slow_llm_step"]["status"] == "failed"
  end

  test "OpenShell uses the step deadline while its command output is buffered" do
    manifest = %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "slow_llm_step",
            "run" => "slow_llm_step",
            "control" => %{"timeout_seconds" => 300}
          }
        ],
        "graph" => %{"edges" => []}
      }
    }

    {state, []} =
      WorkflowLedger.new(manifest, [
        %{
          node_id: "slow_llm_step",
          config: %{
            "runner_module" => "MirrorNeuron.Runner.OpenShell",
            "beacon_timeout_ms" => 45_000
          }
        }
      ])
      |> WorkflowLedger.job_running()

    assert get_in(state, ["steps", "slow_llm_step", "timeout_seconds"]) == 300
    assert get_in(state, ["steps", "slow_llm_step", "beacon_timeout_ms"]) == 300_000
    message = Message.new("job", "runtime", "slow_llm_step", "start", %{})

    {state, _} =
      WorkflowLedger.on_message_received(
        state,
        "slow_llm_step",
        message,
        "2026-06-02T16:00:00.000Z"
      )

    {state, [], []} = reconcile(state, "2026-06-02T16:01:00.000Z")
    assert state["steps"]["slow_llm_step"]["status"] == "running"
    {state, events, _} = reconcile(state, "2026-06-02T16:05:01.000Z")
    assert Enum.any?(events, &(&1.type == :workflow_step_attempt_timed_out))
    assert state["steps"]["slow_llm_step"]["status"] == "failed"
  end

  test "service entrypoint has no implicit deadline while downstream steps stay bounded" do
    manifest = %Manifest{
      type: "service",
      flow: %{
        "entrypoint" => "service",
        "steps" => [
          %{"id" => "service", "run" => "service", "control" => %{}},
          %{"id" => "finalize", "run" => "finalize", "control" => %{}}
        ],
        "graph" => %{
          "edges" => [
            %{"id" => "service_to_finalize", "from" => "service", "to" => "finalize"}
          ]
        }
      }
    }

    nodes = [%{node_id: "service", config: %{}}, %{node_id: "finalize", config: %{}}]
    {state, []} = WorkflowLedger.new(manifest, nodes) |> WorkflowLedger.job_running()

    assert get_in(state, ["steps", "service", "timeout_seconds"]) == nil
    assert get_in(state, ["steps", "service", "beacon_timeout_ms"]) == nil
    assert get_in(state, ["steps", "finalize", "timeout_seconds"]) == 300
    assert get_in(state, ["steps", "finalize", "beacon_timeout_ms"]) == 300_000

    message = Message.new("job", "runtime", "service", "start", %{})
    decorated = WorkflowLedger.decorate_message(state, "service", message)

    refute Map.has_key?(decorated["headers"], "mn.workflow.deadline_at")
    refute Map.has_key?(decorated["headers"], "mn.workflow.heartbeat_deadline_at")

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "service",
        decorated,
        "2026-06-02T16:00:00.000Z"
      )

    assert get_in(state, ["steps", "service", "status"]) == "running"
    assert get_in(state, ["steps", "service", "deadline_at"]) == nil
    assert get_in(state, ["steps", "service", "heartbeat_deadline_at"]) == nil

    {state, [_beacon], []} =
      WorkflowLedger.on_agent_event(
        state,
        "service",
        "agent_beacon",
        %{"step_id" => "service"},
        "2026-06-02T20:00:00.000Z"
      )

    assert get_in(state, ["steps", "service", "heartbeat_deadline_at"]) == nil

    {reconciled, [], []} =
      reconcile(state, "2026-06-03T16:00:00.000Z")

    assert get_in(reconciled, ["steps", "service", "status"]) == "running"
  end

  test "service entrypoint honors an explicit timeout" do
    manifest = %Manifest{
      type: "service",
      flow: %{
        "entrypoint" => "service",
        "steps" => [
          %{
            "id" => "service",
            "run" => "service",
            "control" => %{"timeout_seconds" => 60}
          }
        ],
        "graph" => %{"edges" => []}
      }
    }

    {state, []} =
      WorkflowLedger.new(manifest, [%{node_id: "service", config: %{}}])
      |> WorkflowLedger.job_running()

    assert get_in(state, ["steps", "service", "timeout_seconds"]) == 60
    assert get_in(state, ["steps", "service", "beacon_timeout_ms"]) == 60_000
  end
end
