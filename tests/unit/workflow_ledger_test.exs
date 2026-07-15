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

  test "pause emits blocked events and resume preserves active attempt state" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "start"})
    decorated = WorkflowLedger.decorate_message(state, "step_a", message)

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        decorated,
        "2026-06-02T16:00:00.000Z"
      )

    {paused, [blocked]} = WorkflowLedger.pause(state, "2026-06-02T16:00:01.000Z")

    assert paused["status"] == "paused"
    assert blocked.type == :workflow_step_blocked
    assert blocked.step == "step_a"
    assert blocked["reason"] == "job paused"
    assert blocked["blocked_at"] == "2026-06-02T16:00:01.000Z"
    assert get_in(paused, ["steps", "step_a", "status"]) == "running"

    {resumed, []} = WorkflowLedger.resume(paused, "2026-06-02T16:00:02.000Z")

    assert resumed["status"] == "running"

    assert get_in(resumed, ["steps", "step_a", "current_attempt", "attempt_id"]) ==
             "step_a:attempt:1"

    assert get_in(resumed, ["steps", "step_a", "attempt_count"]) == 1
  end

  test "ignores additional messages while a step attempt is already running" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    first_message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})
    second_message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "second"})

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        WorkflowLedger.decorate_message(state, "step_a", first_message),
        "2026-06-02T16:00:00.000Z"
      )

    {state, [ignored]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        second_message,
        "2026-06-02T16:00:00.100Z"
      )

    assert ignored.type == :workflow_step_duplicate_message_ignored
    assert ignored["reason"] == "workflow step already running"
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1

    assert get_in(state, ["steps", "step_a", "current_attempt", "message_id"]) !=
             Message.id(second_message)
  end

  test "re-receiving the active message is idempotent" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})
    decorated = WorkflowLedger.decorate_message(state, "step_a", message)

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        decorated,
        "2026-06-02T16:00:00.000Z"
      )

    {state, []} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        decorated,
        "2026-06-02T16:00:00.100Z"
      )

    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1
    assert get_in(state, ["steps", "step_a", "status"]) == "running"
    assert get_in(state, ["messages", Message.id(decorated), "status"]) == "running"
  end

  test "ignores late messages after a step is completed" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        WorkflowLedger.decorate_message(state, "step_a", message),
        "2026-06-02T16:00:00.000Z"
      )

    {state, [_completed], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :workflow_step_attempt_completed,
        %{"status" => "completed"},
        "2026-06-02T16:00:01.000Z"
      )

    late_message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "late"})

    {state, [ignored]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        late_message,
        "2026-06-02T16:00:02.000Z"
      )

    assert ignored.type == :workflow_step_duplicate_message_ignored
    assert ignored["reason"] == "workflow step already terminal"
    assert get_in(state, ["steps", "step_a", "status"]) == "completed"
    assert get_in(state, ["steps", "step_a", "attempt_count"]) == 1
  end

  test "ignores late agent events after a step is completed" do
    {state, []} = WorkflowLedger.new(manifest(), runtime_nodes()) |> WorkflowLedger.job_running()
    message = Message.new("job-1", "runtime", "step_a", "init", %{"value" => "first"})

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "step_a",
        WorkflowLedger.decorate_message(state, "step_a", message),
        "2026-06-02T16:00:00.000Z"
      )

    {state, [_completed], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :workflow_step_attempt_completed,
        %{"status" => "completed"},
        "2026-06-02T16:00:01.000Z"
      )

    {state, [ignored], []} =
      WorkflowLedger.on_agent_event(
        state,
        "step_a",
        :agent_beacon,
        %{"status" => "working"},
        "2026-06-02T16:00:02.000Z"
      )

    assert ignored.type == :workflow_step_stale_event_ignored
    assert ignored["reason"] == "workflow step already terminal"
    assert get_in(state, ["steps", "step_a", "status"]) == "completed"
    refute get_in(state, ["steps", "step_a", "heartbeat_deadline_at"])
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
      WorkflowLedger.new(manifest, [%{node_id: "slow_llm_step", config: %{}}])
      |> WorkflowLedger.job_running()

    assert get_in(state, ["steps", "slow_llm_step", "timeout_seconds"]) == 300
    assert get_in(state, ["steps", "slow_llm_step", "beacon_timeout_ms"]) == 300_000
  end

  test "runs a linear pipeline in dependency order" do
    state = dag_state(["a", "b", "c"], [edge("a", "b"), edge("b", "c")])
    {state, [_]} = receive_message(state, "b")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    {state, _, [{:redeliver, "b", "b", message}]} = WorkflowLedger.reconcile(state, timestamp(2))
    state = state |> receive_workflow_message(message) |> elem(0) |> complete_step("b")
    {state, [_]} = receive_message(state, "c")
    state = complete_step(state, "c")
    assert WorkflowLedger.completed?(state)
  end

  test "fans one completed step out to parallel downstream steps" do
    state = dag_state(["a", "b", "c"], [edge("a", "b"), edge("a", "c")])
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    state = state |> receive_message("b") |> elem(0)
    state = state |> receive_message("c") |> elem(0)

    assert get_in(state, ["steps", "b", "status"]) == "running"
    assert get_in(state, ["steps", "c", "status"]) == "running"
  end

  test "fans in only after every required parent succeeds" do
    state =
      dag_state(["a", "b", "c", "join"], [edge("a", "join"), edge("b", "join"), edge("c", "join")])

    {state, [_]} = receive_message(state, "join")

    state =
      Enum.reduce(["a", "b", "c"], state, fn step_id, acc ->
        acc |> receive_message(step_id) |> elem(0) |> complete_step(step_id)
      end)

    {state, _, [{:redeliver, "join", "join", message}]} =
      WorkflowLedger.reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "scatters items into mapped steps and gathers their outputs" do
    state =
      dag_state(["source", "worker", "collect"], [
        edge("source", "worker"),
        edge("worker", "collect")
      ])

    {state, [_]} = receive_message(state, "source")

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "source",
        :workflow_step_scatter,
        %{"target" => "worker", "items" => [%{"id" => 1}, %{"id" => 2}]},
        timestamp(1)
      )

    assert Enum.any?(events, &(&1.type == :workflow_step_scattered))

    assert get_in(state, ["steps", "worker", "status"]) == "skipped"

    state = complete_step(state, "source")
    {state, _, worker_actions} = WorkflowLedger.reconcile(state, timestamp(2))

    assert Enum.map(worker_actions, fn {:redeliver, step_id, _, _} -> step_id end) == [
             "worker[0]",
             "worker[1]"
           ]

    state =
      Enum.reduce(worker_actions, state, fn {:redeliver, _step_id, _agent_id, message}, acc ->
        acc |> receive_workflow_message(message) |> elem(0)
      end)

    {state, [_]} = receive_message(state, "collect")
    state = state |> complete_step("worker[0]") |> complete_step("worker[1]")

    {state, _, [{:redeliver, "collect", "collect", message}]} =
      WorkflowLedger.reconcile(state, timestamp(3))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "collect", "status"]) == "running"
  end

  test "restores mapped items and expanded edges after a coordinator restart" do
    step_specs = ["source", "worker", "collect"]
    edges = [edge("source", "worker"), edge("worker", "collect")]
    state = dag_state(step_specs, edges)
    {state, [_]} = receive_message(state, "source")

    {state, _, []} =
      WorkflowLedger.on_agent_event(
        state,
        "source",
        :workflow_step_scatter,
        %{"target" => "worker", "items" => [%{"id" => 1}, %{"id" => 2}]},
        timestamp(1)
      )

    restored =
      WorkflowLedger.new(
        dag_manifest(step_specs, edges),
        dag_nodes(step_specs),
        %{"workflow_state" => state}
      )

    assert Map.has_key?(restored["steps"], "worker[0]")
    assert Map.has_key?(restored["steps"], "worker[1]")
    assert Enum.any?(restored["edges"], &(&1["from"] == "worker[0]" and &1["to"] == "collect"))
  end

  test "tracks a mapped worker failure against the mapped item" do
    state = dag_state(["source", "worker"], [edge("source", "worker")])
    {state, [_]} = receive_message(state, "source")

    {state, _, _} =
      WorkflowLedger.on_agent_event(
        state,
        "source",
        :workflow_step_scatter,
        %{"target" => "worker", "items" => [%{"id" => 1}]},
        timestamp(1)
      )

    state = complete_step(state, "source")

    {state, _, [{:redeliver, "worker[0]", "worker", message}]} =
      WorkflowLedger.reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)

    {state, _, [{:fail_job, "worker[0]", "worker lost"}]} =
      WorkflowLedger.on_agent_failed(state, "worker", "worker lost", timestamp(3))

    assert get_in(state, ["steps", "worker[0]", "status"]) == "failed"
  end

  test "selects branch targets and skips the unselected branch" do
    state =
      dag_state(
        ["router", "left", "right", {"join", "none_failed_min_one_success"}],
        [
          edge("router", "left"),
          edge("router", "right"),
          edge("left", "join"),
          edge("right", "join")
        ]
      )

    state = state |> receive_message("router") |> elem(0)

    {state, events, _} =
      WorkflowLedger.on_agent_event(
        state,
        "router",
        :workflow_step_branch,
        %{"branches" => ["left"]},
        timestamp(1)
      )

    assert Enum.any?(events, &(&1.type == :workflow_branch_selected))
    assert get_in(state, ["steps", "right", "status"]) == "skipped"
    assert get_in(state, ["steps", "join", "status"]) == "pending"
  end

  test "short circuits and skips every downstream step" do
    state =
      dag_state(["guard", "work", "cleanup"], [edge("guard", "work"), edge("work", "cleanup")])

    state = state |> receive_message("guard") |> elem(0)

    {state, events, _} =
      WorkflowLedger.on_agent_event(
        state,
        "guard",
        :workflow_step_skipped,
        %{"reason" => "no input", "skip_downstream" => true},
        timestamp(1)
      )

    assert Enum.count(events, &(&1.type == :workflow_step_skipped)) == 3
    assert Enum.all?(Map.values(state["steps"]), &(Map.get(&1, "status") == "skipped"))
  end

  test "starts a one-success join after the first successful parent" do
    state = dag_state(["a", "b", {"join", "one_success"}], [edge("a", "join"), edge("b", "join")])
    {state, [_]} = receive_message(state, "join")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")

    {state, _, [{:redeliver, "join", "join", message}]} =
      WorkflowLedger.reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "starts a one-done join after a handled failure" do
    state =
      dag_state([{"a", "all_success", "continue_partial"}, {"join", "one_done"}], [
        edge("a", "join")
      ])

    state = state |> receive_message("a") |> elem(0)

    {state, events, [{:redeliver, "join", "join", message}]} =
      WorkflowLedger.on_agent_failed(state, "a", "provider unavailable", timestamp(1))

    assert Enum.any?(events, &(&1.type == :workflow_step_failed))
    assert get_in(state, ["steps", "a", "terminal_outcome"]) == "failed"
    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "runs a failure handler after the first handled failure" do
    state =
      dag_state([{"a", "all_success", "continue_partial"}, {"alert", "one_failed"}], [
        edge("a", "alert")
      ])

    state = state |> receive_message("a") |> elem(0)

    {state, _, [{:redeliver, "alert", "alert", message}]} =
      WorkflowLedger.on_agent_failed(state, "a", "provider unavailable", timestamp(1))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "alert", "status"]) == "running"
  end

  test "waits for every terminal parent before cleanup" do
    state =
      dag_state(
        ["a", {"b", "all_success", "continue_partial"}, {"cleanup", "all_done"}],
        [edge("a", "cleanup"), edge("b", "cleanup")]
      )

    {state, [_]} = receive_message(state, "cleanup")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    state = state |> receive_message("b") |> elem(0)
    state = state |> on_failed("b", "failed work") |> elem(0)

    {state, _, [{:redeliver, "cleanup", "cleanup", message}]} =
      WorkflowLedger.reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "cleanup", "status"]) == "running"
  end

  test "joins a selected branch when other branches are skipped" do
    state =
      dag_state(
        ["selected", "skipped", {"join", "none_failed_min_one_success"}],
        [edge("selected", "join"), edge("skipped", "join")]
      )

    {state, [_]} = receive_message(state, "join")
    state = state |> receive_message("selected") |> elem(0) |> complete_step("selected")

    {state, _, _} =
      WorkflowLedger.on_agent_event(
        state,
        "skipped",
        :workflow_step_skipped,
        %{"reason" => "branch not selected"},
        timestamp(1)
      )

    {state, _, [{:redeliver, "join", "join", message}]} =
      WorkflowLedger.reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "advances through a fallback chain only after each handled failure" do
    state =
      dag_state(
        [
          {"primary", "all_success", "continue_partial"},
          {"fallback", "one_failed", "continue_partial"},
          {"emergency", "one_failed"}
        ],
        [edge("primary", "fallback"), edge("fallback", "emergency")]
      )

    state = state |> receive_message("primary") |> elem(0)

    {state, _, [{:redeliver, "fallback", "fallback", fallback_message}]} =
      on_failed(state, "primary", "primary unavailable")

    {state, [_]} = receive_workflow_message(state, fallback_message)

    {state, _, [{:redeliver, "emergency", "emergency", emergency_message}]} =
      on_failed(state, "fallback", "fallback unavailable")

    {state, [_]} = receive_workflow_message(state, emergency_message)
    assert get_in(state, ["steps", "emergency", "status"]) == "running"
  end

  test "releases a quorum join after the configured number of successes" do
    state =
      dag_state(
        ["a", "b", "c", {"join", %{"rule" => "quorum_success", "quorum" => 2}}],
        [edge("a", "join"), edge("b", "join"), edge("c", "join")]
      )

    {state, [_]} = receive_message(state, "join")
    state = state |> receive_message("a") |> elem(0) |> complete_step("a")
    state = state |> receive_message("b") |> elem(0) |> complete_step("b")

    {state, _, [{:redeliver, "join", "join", message}]} =
      WorkflowLedger.reconcile(state, timestamp(2))

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "join", "status"]) == "running"
  end

  test "runs teardown after failed work when its all-done trigger is satisfied" do
    state =
      dag_state(
        ["setup", {"work", "all_success", "continue_partial"}, {"teardown", "all_done"}],
        [edge("setup", "work"), edge("work", "teardown")]
      )

    state = state |> receive_message("setup") |> elem(0) |> complete_step("setup")
    state = state |> receive_message("work") |> elem(0)

    {state, _, [{:redeliver, "teardown", "teardown", message}]} =
      on_failed(state, "work", "work failed")

    {state, [_]} = receive_workflow_message(state, message)
    assert get_in(state, ["steps", "teardown", "status"]) == "running"
  end

  test "continues after a sensor receives an external event" do
    state = dag_state(["sensor", "continue"], [edge("sensor", "continue")])

    external =
      Message.new("job", "external", "sensor", "file_arrived", %{"path" => "inbox/report.csv"})

    {state, [_]} = receive_workflow_message(state, external)
    state = complete_step(state, "sensor")
    {state, [_]} = receive_message(state, "continue")
    assert get_in(state, ["steps", "continue", "status"]) == "running"
  end

  defp dag_state(step_specs, edges) do
    manifest = dag_manifest(step_specs, edges)
    nodes = dag_nodes(step_specs)

    {state, []} = WorkflowLedger.new(manifest, nodes) |> WorkflowLedger.job_running(timestamp(0))
    state
  end

  defp dag_manifest(step_specs, edges) do
    %Manifest{
      flow: %{
        "steps" => Enum.map(step_specs, &dag_step/1),
        "graph" => %{"edges" => edges}
      }
    }
  end

  defp dag_nodes(step_specs) do
    Enum.map(step_specs, fn spec ->
      step_id = spec |> dag_step() |> Map.fetch!("id")
      %{node_id: step_id, config: %{"timeout_seconds" => 10, "max_attempts" => 1}}
    end)
  end

  defp dag_step({id, trigger_rule, failure_policy}) do
    dag_step(id)
    |> Map.put("trigger_rule", trigger_rule)
    |> put_in(["control", "failure_policy"], failure_policy)
  end

  defp dag_step({id, trigger_rule}), do: dag_step(id) |> Map.put("trigger_rule", trigger_rule)

  defp dag_step(id) when is_binary(id) do
    %{
      "id" => id,
      "run" => id,
      "control" => %{
        "required" => true,
        "failure_policy" => "fail_workflow",
        "timeout_seconds" => 10,
        "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
      }
    }
  end

  defp edge(from, to) do
    %{
      "id" => "#{from}_to_#{to}",
      "from" => from,
      "to" => to,
      "accepts" => ["done"],
      "required" => true
    }
  end

  defp receive_message(state, step_id) do
    message = Message.new("job", "upstream", step_id, "done", %{})
    receive_workflow_message(state, message)
  end

  defp receive_workflow_message(state, message) do
    WorkflowLedger.on_message_received(state, Message.to(message), message, timestamp(0))
  end

  defp complete_step(state, step_id) do
    {state, _events, _actions} =
      WorkflowLedger.on_agent_event(
        state,
        step_id,
        :workflow_step_attempt_completed,
        %{"step_id" => step_id, "status" => "completed"},
        timestamp(1)
      )

    state
  end

  defp on_failed(state, step_id, reason) do
    WorkflowLedger.on_agent_failed(state, step_id, reason, timestamp(1))
  end

  defp timestamp(offset_seconds) do
    "2026-06-02T16:00:#{offset_seconds |> Integer.to_string() |> String.pad_leading(2, "0")}.000Z"
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
