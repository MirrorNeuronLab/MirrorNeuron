defmodule MirrorNeuron.Runtime.WorkflowLedgerTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.WorkflowLedger

  test "tracks workflow attempts, retries timed out steps, and fails after attempts are exhausted" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "start"})

    decorated = WorkflowLedger.decorate_message(state, "step_a", message)
    assert decorated["headers"]["mn.workflow.step_id"] == "step_a"

    {state, [started]} =
      WorkflowLedger.on_message_received(state, "step_a", decorated, "2026-06-02T16:00:00.000Z")

    assert started.type == :workflow_step_attempt_started
    assert started.step == "step_a"
    assert get_in(state, ["steps", "step_a", "status"]) == "running"
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1

    assert get_in(state, ["steps", "step_a", "current_attempt", "attempt_id"]) ==
             "step_a:attempt:1"

    {state, events, actions} = WorkflowLedger.reconcile(state, "2026-06-02T16:00:02.000Z")

    assert Enum.any?(events, &(&1.type == :workflow_step_attempt_timed_out))
    assert Enum.any?(events, &(&1.type == :workflow_step_attempt_retry_scheduled))
    assert {:terminate_agent, "step_a", _reason} = List.first(actions)
    assert get_in(state, ["steps", "step_a", "status"]) == "retry_wait"

    {state, [], [{:redeliver, "step_a", "step_a", retry_message}]} =
      WorkflowLedger.reconcile(state, "2026-06-02T16:00:04.000Z")

    assert retry_message["headers"]["mn.workflow.attempt_id"] == "step_a:attempt:2"
    assert retry_message["headers"]["mn.workflow.attempt"] == 2
    assert get_in(state, ["steps", "step_a", "status"]) == "queued"

    {state, [second_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        retry_message,
        "2026-06-02T16:00:04.100Z"
      )

    assert second_started.attempt == 2
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 2

    {state, events, actions} = WorkflowLedger.reconcile(state, "2026-06-02T16:00:06.000Z")

    failed_event = Enum.find(events, &(&1.type == :workflow_step_failed))
    assert failed_event
    assert failed_event["error"]["schema_version"] == "mn.error.v1"
    assert failed_event["error"]["details"]["step_id"] == "step_a"
    assert {:fail_job, "step_a", _reason} = List.last(actions)
    assert get_in(state, ["steps", "step_a", "status"]) == "failed"
    assert get_in(state, ["steps", "step_a", "terminal_error", "schema_version"]) == "mn.error.v1"
  end

  test "resolves optional steps as partial after retry exhaustion" do
    {state, []} =
      WorkflowLedger.new(manifest(required?: false), runtime_nodes())
      |> WorkflowLedger.job_running()

    message = Message.new("job-1", "runtime", "step_a", "init", %{})

    {state, [_started]} =
      state
      |> WorkflowLedger.decorate_message("step_a", message)
      |> then(
        &WorkflowLedger.on_message_received(state, "step_a", &1, "2026-06-02T16:00:00.000Z")
      )

    {state, events, actions} = WorkflowLedger.reconcile(state, "2026-06-02T16:00:02.000Z")

    assert actions == [{:terminate_agent, "step_a", "workflow step deadline exceeded"}]
    assert Enum.any?(events, &(&1.type == :workflow_step_partial))
    assert get_in(state, ["steps", "step_a", "status"]) == "partial"
  end

  test "blocks early join messages and redelivers when dependencies are satisfied" do
    {state, []} =
      WorkflowLedger.new(join_manifest(), join_runtime_nodes())
      |> WorkflowLedger.job_running()

    join_message = Message.new("job-1", "step_a", "join_step", "a_done", %{"value" => "early"})

    {state, [blocked]} =
      WorkflowLedger.on_message_received(
        state,
        "join_step",
        join_message,
        "2026-06-02T16:00:00.000Z"
      )

    assert blocked.type == :workflow_step_blocked
    assert get_in(state, ["steps", "join_step", "status"]) == "blocked"

    {state, [completed], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :workflow_step_attempt_completed,
        %{"status" => "completed"},
        "2026-06-02T16:00:01.000Z"
      )

    assert completed.type == :workflow_step_completed

    {state, [], [{:redeliver, "join_step", "join_step", redelivered}]} =
      WorkflowLedger.reconcile(state, "2026-06-02T16:00:02.000Z")

    assert redelivered == join_message
    assert get_in(state, ["steps", "join_step", "status"]) == "queued"
  end

  test "restores persisted workflow state after coordinator restart" do
    existing_job = %{
      "workflow_state" => %{
        "enabled" => true,
        "run_id" => "run-persisted",
        "created_at" => "2026-06-02T15:59:00.000Z",
        "updated_at" => "2026-06-02T16:00:01.000Z",
        "status" => "running",
        "messages" => %{
          "msg-1" => %{"status" => "acked", "step_id" => "step_a"}
        },
        "steps" => %{
          "step_a" => %{
            "status" => "retry_wait",
            "attempt_count" => 1,
            "current_attempt" => %{"attempt_id" => "step_a:attempt:1"},
            "retry_at" => "2026-06-02T16:00:04.000Z"
          },
          "removed_step" => %{"status" => "running"}
        }
      }
    }

    state = WorkflowLedger.new(manifest(), runtime_nodes(), existing_job)

    assert state["run_id"] == "run-persisted"
    assert state["created_at"] == "2026-06-02T15:59:00.000Z"
    assert state["status"] == "running"
    assert get_in(state, ["messages", "msg-1", "status"]) == "acked"

    assert get_in(state, ["steps", "step_a", "status"]) == "retry_wait"
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1
    assert get_in(state, ["steps", "step_a", "timeout_seconds"]) == 1

    assert get_in(state, ["steps", "step_a", "current_attempt", "attempt_id"]) ==
             "step_a:attempt:1"

    refute Map.has_key?(state["steps"], "removed_step")
  end

  defp manifest(opts \\ []) do
    required? = Keyword.get(opts, :required?, true)

    %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "step_a",
            "run" => "step_a",
            "label" => "Step A",
            "control" => %{
              "required" => required?,
              "failure_policy" => if(required?, do: "fail_workflow", else: "continue_partial"),
              "timeout_seconds" => 1,
              "retry" => %{
                "max_attempts" => if(required?, do: 2, else: 1),
                "backoff_seconds" => 1
              }
            }
          }
        ],
        "graph" => %{"edges" => []}
      }
    }
  end

  defp runtime_nodes do
    [
      %{
        node_id: "step_a",
        config: %{
          "timeout_seconds" => 1,
          "beacon_timeout_ms" => 1_000,
          "max_attempts" => 2,
          "retry_backoff_ms" => 1_000
        }
      }
    ]
  end

  defp join_manifest do
    %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "step_a",
            "run" => "step_a",
            "label" => "Step A",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 5,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 1}
            }
          },
          %{
            "id" => "join_step",
            "run" => "join_step",
            "label" => "Join Step",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 5,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 1}
            }
          }
        ],
        "graph" => %{
          "edges" => [
            %{
              "id" => "step_a_to_join_step",
              "from" => "step_a",
              "to" => "join_step",
              "event" => "a_done",
              "accepts" => ["done"],
              "required" => true
            }
          ]
        }
      }
    }
  end

  defp join_runtime_nodes do
    [
      %{node_id: "step_a", config: %{"timeout_seconds" => 5}},
      %{node_id: "join_step", config: %{"timeout_seconds" => 5}}
    ]
  end
end
