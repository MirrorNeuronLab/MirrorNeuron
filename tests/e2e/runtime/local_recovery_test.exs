defmodule MirrorNeuron.Runtime.LocalRecoveryTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.RuntimeTest.CrashOnceCounter
  alias MirrorNeuron.RuntimeTest.CrashOnceRunner
  alias MirrorNeuron.RuntimeTest.SafeRetryRunner

  test "paused owner loss requires a clean attempt and discards queued attempt work" do
    manifest = pause_resume_dag_manifest("pause_resume_recovery_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_paused?(job_id, "sink") end)
    assert_runtime_workflow_manifest(job_id)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved across restart"}
             })

    wait_until(fn -> agent_pending_count(job_id, "sink") == 1 end)

    old_coordinator = job_coordinator_pid(job_id)
    Process.exit(old_coordinator, :kill)

    wait_until(fn -> not Process.alive?(old_coordinator) end, 3_000)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 3_000)

    assert {:ok, paused_job} = MirrorNeuron.inspect_job(job_id)
    assert paused_job["status"] == "paused"
    assert paused_job["recovery_mode"] == "clean_restart"
    assert paused_job["recovery_requires_review"] == true

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)

    wait_until(
      fn ->
        with {:ok, job} <- MirrorNeuron.inspect_job(job_id) do
          job["status"] == "running" and job["attempt"] == 2 and
            job["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "sink")
        else
          _ -> false
        end
      end,
      3_000
    )

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved on clean attempt"}
             })

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert job["attempt"] == 2

    assert get_in(job, ["result", "output", "last_message", "text"]) ==
             "approved on clean attempt"

    assert_runtime_workflow_manifest(job_id)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_paused_for_manual_restart"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))

    RedisStore.delete_job(job_id)
  end

  test "manual resume pauses and restarts a running orphaned job after local process loss" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "manual_resume_running_orphan_test",
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
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, %{"status" => "running"}} = MirrorNeuron.inspect_job(job_id)
    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    wait_until(fn -> running_status?(job_id) and job_runner_pid(job_id, false) != nil end, 3_000)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert job["attempt"] == 2
    assert job["lease_epoch"] > first_epoch
    assert job["recovery_mode"] == "clean_restart"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_paused_for_manual_resume"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))

    cleanup_runtime_job(job_id)
  end

  test "local recovery redoes declared inputs when the manifest is explicitly safe" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "safe_inflight_retry_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 42}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => config
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    scheduler_plan = %{
      "status" => "scheduled",
      "job_type" => "batch",
      "strategy" => "binpack",
      "placements" => [
        %{
          "agent_id" => "worker",
          "node" => to_string(Node.self()),
          "allocations" => %{
            "ports" => [
              %{"label" => "mcp-collaboration", "port" => 62_000, "protocol" => "http"}
            ]
          }
        }
      ]
    }

    {:ok, job_id} =
      persist_recoverable_job(manifest, "safe-retry", %{"scheduler" => scheduler_plan})

    assert {:ok, %{action: :started}} = MirrorNeuron.recover_job(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert job["scheduler"] == scheduler_plan
    assert get_in(job, ["result", "output", "payload", "value"]) == 42
    assert get_in(job, ["result", "output", "retried"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.any?(events, &(&1["type"] == "sandbox_job_completed"))

    RedisStore.delete_job(job_id)
  end

  test "lease loss fences the old attempt and redoes safe declared input" do
    {:ok, counter_pid} = start_supervised(CrashOnceCounter)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "hibernate_retry_recovery_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 42}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => CrashOnceRunner,
            "safe_to_retry" => true,
            "max_attempts" => 1,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => 3,
          "interval_ms" => 60_000,
          "delay_ms" => 2_000,
          "delay_function" => "constant",
          "max_delay_ms" => 2_000,
          "mode" => "fail"
        }
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)

    wait_until(fn -> CrashOnceCounter.invocations() == 1 end, 3_000)

    assert {:ok, job_before_recovery} = RedisStore.fetch_job(job_id)
    assert job_before_recovery["attempt"] == 1
    first_epoch = job_before_recovery["lease_epoch"]
    first_owner = job_before_recovery["lease_owner"]

    assert :ok = RedisStore.release_fenced_lease("job:#{job_id}", first_owner, first_epoch)

    [{runner_pid, _meta}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id})

    send(runner_pid, :renew_lease)

    wait_until(fn -> not Process.alive?(runner_pid) end, 3_000)

    assert {:ok, recovery} = MirrorNeuron.recover_unfinished_jobs(reason: "hibernate_test")

    assert Enum.any?(
             recovery.jobs,
             &(&1.job_id == job_id and &1.action in [:started, :already_running])
           )

    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 6_000)
    assert completed["status"] == "completed"
    assert completed["attempt"] == 2
    assert get_in(completed, ["result", "output", "invocation"]) == 2
    assert get_in(completed, ["result", "output", "recovered"]) == true
    assert completed["lease_epoch"] > first_epoch

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_lease_lost"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))
    refute Enum.any?(events, &(&1["type"] == "agent_policy_action_restored"))

    GenServer.stop(counter_pid)
    RedisStore.delete_job(job_id)
  end
end
