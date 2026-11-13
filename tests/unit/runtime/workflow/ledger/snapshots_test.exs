defmodule MirrorNeuron.Runtime.WorkflowLedger.SnapshotsTest do
  use MirrorNeuron.WorkflowLedgerCase, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Runtime.WorkflowLedger

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

  @tag :tmp_dir
  test "persistable snapshot externalizes step outputs and retry messages", %{tmp_dir: tmp_dir} do
    submission = Path.join(tmp_dir, "submission")
    large_output = %{"nested" => String.duplicate("result", 200_000)}
    message = Message.new("job-1", "source", "worker", "run", %{"input" => large_output})

    state = %{
      "enabled" => true,
      "job_id" => "job-1",
      "run_id" => "run-1",
      "steps" => %{
        "worker" => %{
          "id" => "worker",
          "status" => "running",
          "output" => large_output,
          "last_message" => message
        }
      }
    }

    manifest = %{
      "metadata" => %{
        "mn_storage" => %{
          "submission_id" => "submission-1",
          "submission_path" => submission
        }
      }
    }

    persisted = WorkflowLedger.persistable_snapshot(state, manifest)
    step = persisted["steps"]["worker"]

    refute Map.has_key?(step, "output")
    refute Map.has_key?(step, "last_message")

    assert StagedArtifact.resolve!(step["output_ref"], submission_path: submission) ==
             large_output

    assert StagedArtifact.resolve!(step["last_message_ref"], submission_path: submission) ==
             message

    assert byte_size(Jason.encode!(persisted)) < 10_000
  end
end
