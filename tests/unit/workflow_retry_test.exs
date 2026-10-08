defmodule MirrorNeuron.Runtime.WorkflowRetryTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.{Manifest, Message}
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Runtime.{RunRetry, WorkflowLedger, WorkflowRetry, RunClock}

  @tag :tmp_dir
  test "retry reopens dependency skips after checkpoint outputs are externalized", %{
    tmp_dir: root
  } do
    previous = System.get_env("MN_SHARED_STORAGE_ROOT")
    System.put_env("MN_SHARED_STORAGE_ROOT", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_SHARED_STORAGE_ROOT", previous),
        else: System.delete_env("MN_SHARED_STORAGE_ROOT")
    end)

    manifest = %{
      "metadata" => %{
        "mn_storage" => %{
          "submission_id" => "retry-skip",
          "submission_path" => Path.join([root, "submissions", "retry-skip"])
        }
      }
    }

    ledger = %{
      "enabled" => true,
      "schema_version" => 3,
      "run_id" => "retry-skip-run",
      "step_order" => ["index", "investigate", "report", "unselected"],
      "steps" => %{
        "index" => %{"id" => "index", "status" => "failed"},
        "investigate" => %{
          "id" => "investigate",
          "status" => "skipped",
          "needs" => ["index"],
          "output" => %{"reason" => "trigger rule cannot be satisfied"}
        },
        "report" => %{
          "id" => "report",
          "status" => "skipped",
          "needs" => ["investigate"],
          "output" => %{"reason" => "trigger rule cannot be satisfied"}
        },
        "unselected" => %{
          "id" => "unselected",
          "status" => "skipped",
          "output" => %{"reason" => "branch not selected"}
        }
      }
    }

    checkpoint = WorkflowLedger.persistable_snapshot(ledger, manifest)
    refute Map.has_key?(checkpoint["steps"]["investigate"], "output")
    assert StagedArtifact.ref?(checkpoint["steps"]["investigate"]["output_ref"])
    assert WorkflowRetry.preserved(checkpoint) == ["unselected"]
    assert WorkflowRetry.unfinished(checkpoint) == ["index", "investigate", "report"]

    assert {:ok, restored} = WorkflowRetry.restore(checkpoint, "now")
    assert restored["steps"]["investigate"]["status"] == "pending"
    assert restored["steps"]["report"]["status"] == "pending"
    assert restored["steps"]["unselected"] == checkpoint["steps"]["unselected"]

    reference = checkpoint["steps"]["investigate"]["output_ref"]

    wrapped =
      checkpoint
      |> update_in(["steps", "investigate"], fn step ->
        step
        |> Map.delete("output_ref")
        |> Map.put("output", %{StagedArtifact.output_key() => reference})
      end)

    assert {:ok, restored} = WorkflowRetry.restore(wrapped, "now")
    assert restored["steps"]["investigate"]["status"] == "pending"

    target = Path.join([root, "submissions", "retry-skip", reference["relative_path"]])
    File.write!(target, "{}")

    assert_raise StagedArtifact.IntegrityError, fn ->
      WorkflowRetry.restore(checkpoint, "now")
    end

    File.rm!(target)

    assert_raise StagedArtifact.NotReadyError, fn ->
      WorkflowRetry.restore(checkpoint, "now")
    end
  end

  test "retains completed branches and graph state and resets unfinished attempts" do
    completed = %{"id" => "done", "status" => "completed", "output" => %{"answer" => 42}}

    failed = %{
      "id" => "work",
      "status" => "failed",
      "attempt_count" => 2,
      "current_attempt" => %{"idempotency_key" => "effect-key"},
      "deadline_at" => "old",
      "instance_input" => %{"item" => 7}
    }

    ledger = %{
      "enabled" => true,
      "schema_version" => 3,
      "steps" => %{"done" => completed, "work" => failed},
      "step_order" => ["done", "work"],
      "edges" => [%{"from" => "done", "to" => "work"}],
      "graph_revision" => 3,
      "applied_patches" => %{"patch-1" => %{}},
      "messages" => %{"old" => %{}},
      "child_workflows" => %{}
    }

    assert {:ok, restored} = WorkflowRetry.restore(ledger, "now")
    assert restored["steps"]["done"] == completed
    assert restored["graph_revision"] == 3
    assert restored["edges"] == ledger["edges"]
    assert restored["messages"] == %{}
    assert restored["steps"]["work"]["status"] == "pending"
    assert restored["steps"]["work"]["instance_input"] == %{"item" => 7}
    assert restored["steps"]["work"]["retry_idempotency_key"] == "effect-key"
    assert restored["steps"]["work"]["deadline_at"] == nil
    assert ledger["steps"]["work"]["status"] == "failed"
  end

  test "preserves child results and retries the unfinished child without replaying its parent" do
    ledger = %{
      "enabled" => true,
      "schema_version" => 3,
      "step_order" => ["parent", "done", "task"],
      "steps" => %{
        "parent" => %{"id" => "parent", "status" => "failed"},
        "done" => %{"id" => "done", "status" => "completed", "output" => %{"saved" => true}},
        "task" => %{"id" => "task", "status" => "running", "parent_step_id" => "parent"}
      },
      "child_workflows" => %{
        "parent" => %{
          "phase" => "executing",
          "revision" => 4,
          "active" => ["done", "task"],
          "results" => []
        }
      }
    }

    assert {:ok, restored} = WorkflowRetry.restore(ledger, "now")
    assert restored["steps"]["parent"]["status"] == "waiting"
    assert restored["steps"]["task"]["status"] == "pending"
    assert restored["child_workflows"] == ledger["child_workflows"]
    refute "done" in WorkflowRetry.unfinished(restored)

    assert {:error, _} =
             WorkflowRetry.restore(
               put_in(ledger, ["child_workflows", "parent", "phase"], "failed"),
               "now"
             )

    assert {:error, _} = WorkflowRetry.restore(%{"schema_version" => 2}, "now")
  end

  test "manual delivery gets a new identity while retaining the logical effect key" do
    node = %{node_id: "worker", config: %{}}

    manifest = %Manifest{
      flow: %{
        "steps" => [%{"id" => "work", "run" => "worker", "agent_ids" => ["worker"]}],
        "graph" => %{"edges" => []}
      }
    }

    {ledger, []} =
      WorkflowLedger.new(manifest, [node], nil, "run-1") |> WorkflowLedger.job_running()

    message = Message.new("run-1", "runtime", "worker", "init", %{"value" => 1})

    {ledger, [_event]} =
      WorkflowLedger.on_message_received(ledger, "worker", message, "2026-10-01T10:00:00Z")

    key = ledger["steps"]["work"]["current_attempt"]["idempotency_key"]
    ledger = put_in(ledger, ["steps", "work", "status"], "failed")
    assert {:ok, restored} = WorkflowRetry.restore(ledger, "2026-10-01T10:20:00Z")

    {next, _, [{:redeliver, "work", "worker", delivery}]} =
      WorkflowLedger.reconcile(restored, "2026-10-01T10:20:00Z")

    refute Message.id(delivery) == Message.id(message)
    assert delivery["headers"]["mn.workflow.idempotency_key"] == key
    assert delivery["headers"]["mn.workflow.attempt"] == 2
    assert next["steps"]["work"]["status"] == "queued"
  end

  test "checkpoint digest is deterministic and tracks original identity" do
    job = %{
      "run_id" => "run",
      "stable_job_id" => "job",
      "attempt" => 2,
      "data_generation" => 3,
      "manifest" => %{"b" => 2, "a" => 1},
      "inputs" => %{"x" => 1}
    }

    cp = RunRetry.checkpoint(job, %{})
    assert cp["inputs_digest"] == RunRetry.digest(job["inputs"])
    assert cp["revision"] == RunRetry.digest(Map.delete(cp, "revision"))
    assert RunRetry.digest(%{"b" => 2, "a" => 1}) == RunRetry.digest(%{"a" => 1, "b" => 2})
  end

  test "retry excludes failed waiting time from the run-wide clock" do
    prior = %{
      "status" => "failed",
      "updated_at" => "2026-10-01T10:20:00Z",
      "running_time" => %{
        "accumulated_ms" => 1_200_000,
        "active_since" => nil,
        "complete" => true
      }
    }

    now = %{
      "status" => "running",
      "updated_at" => "2026-10-02T10:20:00Z",
      "clock_session" => "retry"
    }

    assert RunClock.advance(prior, now)["accumulated_ms"] == 1_200_000
  end
end
