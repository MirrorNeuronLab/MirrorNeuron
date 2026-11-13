defmodule MirrorNeuron.Runtime.CancellationTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.RuntimeTest.DelayedCompleteRunner
  alias MirrorNeuron.RuntimeTest.LongSleepRunner

  test "can pause and cancel a single-run executor job before it completes" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cancel_once_test",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "cancel me"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => DelayedCompleteRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)

    wait_until(
      fn ->
        match?({:ok, %{"status" => "paused"}}, MirrorNeuron.inspect_job(job_id))
      end,
      2_000
    )

    assert {:ok, cancellation_status} = MirrorNeuron.cancel(job_id)
    assert cancellation_status in ["cancelled", "cancellation_pending"]

    if cancellation_status == "cancellation_pending" do
      assert :ok = MirrorNeuron.Runtime.CancellationReconciler.reconcile_now(job_id)
    end

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "cancelled"
    assert get_in(job, ["result", "reason"]) == "cancelled by durable cluster cancellation"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert_event_before(events, "job_pausing", "job_paused")
    assert_event_before(events, "job_paused", "job_cancelled")

    RedisStore.delete_job(job_id)
  end

  test "cleanup all cancels live jobs before deleting their persisted state" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "safe_live_cleanup_test",
      "type" => "service",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "router",
          "role" => "root_coordinator"
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)
    assert job_runner_pid(job_id, false) != nil

    assert {:ok, result} = Runtime.cleanup_jobs(all: true)
    assert job_id in result.deleted_jobs

    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)
    assert Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) == []

    assert Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"}) ==
             []

    assert {:error, _reason} = RedisStore.fetch_job(job_id)
  end

  test "cleanup all preserves active state when the runtime cannot be stopped" do
    job_id = "unsafe-live-cleanup-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "unsafe_live_cleanup",
               "job_name" => "unsafe live cleanup",
               "status" => "running",
               "submitted_at" => Runtime.timestamp(),
               "updated_at" => Runtime.timestamp()
             })

    assert {:ok, result} = Runtime.cleanup_jobs(all: true)
    refute job_id in result.deleted_jobs
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(job_id)

    RedisStore.delete_job(job_id)
  end

  test "cancel terminates busy agent workers instead of waiting for queued cancel casts" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cancel_busy_worker_test",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "cancel busy"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => LongSleepRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(fn -> event_count(job_id, "agent_message_received") >= 1 end, 2_000)

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)

    wait_until(fn -> agent_unregistered?(job_id, "root") end, 2_000)
    wait_until(fn -> agent_unregistered?(job_id, "worker") end, 2_000)
    wait_until(fn -> job_runner_unregistered?(job_id) end, 2_000)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "cancelled"

    RedisStore.delete_job(job_id)
  end

  test "can cancel a long-lived job and it disappears from the live list" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cancel_service_test",
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "manual_result"}
        },
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_after" => 10, "terminal_sink" => true, "complete_run" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        {:ok, jobs} = MirrorNeuron.list_jobs(live_only: true, include_terminal: true)
        Enum.any?(jobs, &(&1["job_id"] == job_id))
      end,
      2_000
    )

    assert {:ok, cancellation_status} = MirrorNeuron.cancel(job_id)
    assert cancellation_status in ["cancelled", "cancellation_pending"]

    if cancellation_status == "cancellation_pending" do
      assert :ok = MirrorNeuron.Runtime.CancellationReconciler.reconcile_now(job_id)
    end

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "cancelled"

    wait_until(
      fn ->
        {:ok, jobs} = MirrorNeuron.list_jobs(live_only: true, include_terminal: true)
        Enum.all?(jobs, &(&1["job_id"] != job_id))
      end,
      2_000
    )

    RedisStore.delete_job(job_id)
  end
end
