defmodule MirrorNeuron.MonitorTest.CleanupTest do
  use MirrorNeuron.MonitorCase, async: false

  alias MirrorNeuron.Monitor
  alias MirrorNeuron.Persistence.RedisStore

  test "clear_jobs removes safely cleanable terminal jobs and preserves running jobs" do
    running_id = "monitor-running-#{System.unique_integer([:positive])}"
    failed_id = "monitor-failed-#{System.unique_integer([:positive])}"
    cancelled_id = "monitor-cancelled-#{System.unique_integer([:positive])}"
    outside_submission = Path.join(System.tmp_dir!(), "mn-monitor-outside-#{cancelled_id}")

    File.mkdir_p!(outside_submission)

    on_exit(fn ->
      File.rm_rf(outside_submission)
    end)

    RedisStore.persist_job(running_id, %{
      "job_id" => running_id,
      "graph_id" => "clear_demo",
      "status" => "running",
      "submitted_at" => "2026-03-28T00:00:00Z",
      "updated_at" => "2026-03-28T00:00:05Z"
    })

    RedisStore.persist_job(failed_id, %{
      "job_id" => failed_id,
      "graph_id" => "clear_demo",
      "status" => "failed",
      "submitted_at" => "2026-03-28T00:00:00Z",
      "updated_at" => "2026-03-28T00:00:05Z"
    })

    RedisStore.persist_job(cancelled_id, %{
      "job_id" => cancelled_id,
      "graph_id" => "clear_demo",
      "status" => "cancelled",
      "recovery_status" => "paused_for_review",
      "active_executors" => 1,
      "manifest" => %{
        "metadata" => %{
          "mn_storage" => %{"submission_path" => outside_submission}
        }
      },
      "submitted_at" => "2026-03-28T00:00:00Z",
      "updated_at" => "2026-03-28T00:00:05Z"
    })

    # A job whose declared shared-storage submission path is outside the
    # configured root must remain visible for manual remediation. Deleting its
    # record would orphan unverified user data; RedisStore.delete_job enforces
    # the same contract directly.
    assert {:ok, 1} = Monitor.clear_jobs()
    assert {:ok, jobs} = Monitor.list_jobs(summary: :basic)
    assert Enum.any?(jobs, &(&1["job_id"] == running_id))
    refute Enum.any?(jobs, &(&1["job_id"] == failed_id))
    assert Enum.any?(jobs, &(&1["job_id"] == cancelled_id))
    assert File.dir?(outside_submission)

    assert {:ok, cancelled} = RedisStore.fetch_job(cancelled_id)

    assert {:ok, _cancelled} =
             RedisStore.persist_job(cancelled_id, Map.put(cancelled, "manifest", %{}))

    assert :ok = RedisStore.delete_job(cancelled_id)
    RedisStore.delete_job(running_id)
  end
end
