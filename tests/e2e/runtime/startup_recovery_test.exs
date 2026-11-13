defmodule MirrorNeuron.Runtime.StartupRecoveryTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.ServiceRegistry
  alias MirrorNeuron.RuntimeTest.SafeRetryRunner
  alias MirrorNeuron.RuntimeTest.DurableCounterAgent

  test "startup scan starts a clean safe attempt from declared inputs" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_reboot_resume_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{
            "module" => DurableCounterAgent,
            "target" => 8,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    send_counter_messages(job_id, 1..5)
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 5 end, 1_000)

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, job_after_stop} = MirrorNeuron.inspect_job(job_id)
    assert job_after_stop["status"] == "running"
    refute get_in(job_after_stop, ["result", "agent_id"]) == "job_runner"

    assert {:ok, result} = MirrorNeuron.recover_unfinished_jobs(reason: "test_startup_scan")
    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    wait_until(
      fn ->
        with {:ok, job} <- MirrorNeuron.inspect_job(job_id) do
          job["status"] == "running" and job["attempt"] == 2 and
            job["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "counter")
        else
          _ -> false
        end
      end,
      3_000
    )

    send_counter_messages(job_id, 1..8)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "count"]) == 8
    assert get_in(job, ["result", "output", "seen_ids"]) == Enum.to_list(1..8)

    assert job["attempt"] == 2
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 13 end, 1_000)
    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))
    assert Enum.count(events, &(&1["type"] == "counter_step_completed")) == 13

    RedisStore.delete_job(job_id)
  end

  test "graceful runtime shutdown keeps a running job recoverable on startup scan" do
    # This test controls the startup scan explicitly. A periodic scan may
    # otherwise recover the runner before we can observe its shutdown.
    recovery = Process.whereis(MirrorNeuron.Runtime.LocalRecovery)
    :ok = :sys.suspend(recovery)

    on_exit(fn ->
      if Process.alive?(recovery), do: :sys.resume(recovery)
    end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_graceful_runtime_restart_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{
            "module" => DurableCounterAgent,
            "target" => 6,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    send_counter_messages(job_id, 1..3)
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 3 end, 2_000)

    old_coordinator = job_coordinator_pid(job_id)
    :ok = GenServer.stop(old_coordinator, :normal, 1_000)

    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)
    wait_until(fn -> match?({:ok, nil}, RedisStore.get_lease("job:#{job_id}")) end, 2_000)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    refute get_in(job, ["result", "agent_id"]) == "job_runner"

    assert {:ok, result} =
             MirrorNeuron.recover_unfinished_jobs(reason: "test_graceful_restart_scan")

    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    wait_until(
      fn ->
        with {:ok, restarted} <- MirrorNeuron.inspect_job(job_id) do
          restarted["status"] == "running" and restarted["attempt"] == 2 and
            restarted["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "counter")
        else
          _ -> false
        end
      end,
      3_000
    )

    send_counter_messages(job_id, 1..6)

    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert completed["attempt"] == 2
    assert get_in(completed, ["result", "output", "count"]) == 6
    assert get_in(completed, ["result", "output", "seen_ids"]) == Enum.to_list(1..6)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_recovery_scheduled"))
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))

    RedisStore.delete_job(job_id)
  end

  test "startup scan repairs a missing job index before recovery" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_reboot_index_repair_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{
            "module" => DurableCounterAgent,
            "target" => 3,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    send_counter_messages(job_id, 1..1)
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 1 end, 1_000)

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SREM",
               redis_key(["jobs"]),
               job_id
             ])

    assert {:ok, result} = MirrorNeuron.recover_unfinished_jobs(reason: "test_index_repair")
    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    wait_until(
      fn ->
        with {:ok, restarted} <- MirrorNeuron.inspect_job(job_id) do
          restarted["status"] == "running" and restarted["attempt"] == 2 and
            restarted["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "counter")
        else
          _ -> false
        end
      end,
      3_000
    )

    send_counter_messages(job_id, 1..3)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert job["attempt"] == 2
    assert get_in(job, ["result", "output", "count"]) == 3
    assert get_in(job, ["result", "output", "seen_ids"]) == Enum.to_list(1..3)

    wait_until(fn -> event_count(job_id, "counter_step_completed") == 4 end, 1_000)
    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.count(events, &(&1["type"] == "counter_step_completed")) == 4

    RedisStore.delete_job(job_id)
  end

  test "startup scan recovers jobs falsely marked failed by runner shutdown" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "false_failed_runner_recovery_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 123}]},
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

    {:ok, job_id} = persist_recoverable_job(manifest, "false-failed")
    cleanup_job_on_exit(job_id)

    assert {:ok, job} = RedisStore.fetch_job(job_id)

    assert {:ok, _job} =
             RedisStore.persist_job(
               job_id,
               Map.merge(job, %{
                 "status" => "failed",
                 "result" => %{
                   "agent_id" => "job_runner",
                   "error" => "job coordinator exited before terminal state",
                   "reason" => ":normal"
                 }
               })
             )

    assert {:ok, recovered} = MirrorNeuron.recover_job(job_id)
    assert recovered.action in [:started, :already_running]

    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert get_in(completed, ["result", "output", "payload", "value"]) == 123
    assert get_in(completed, ["result", "output", "retried"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))

    RedisStore.delete_job(job_id)
  end

  test "startup scan keeps real failed jobs terminal" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "real_failed_terminal_recovery_guard_test",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "role" => "root_coordinator",
          "config" => %{"complete_after" => 1, "terminal_sink" => true, "complete_run" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "real-failed")
    assert {:ok, job} = RedisStore.fetch_job(job_id)

    assert {:ok, _job} =
             RedisStore.persist_job(
               job_id,
               Map.merge(job, %{
                 "status" => "failed",
                 "result" => %{"agent_id" => "sink", "error" => "actual workflow failure"}
               })
             )

    assert {:ok, %{action: :skipped, reason: "job is failed"}} = MirrorNeuron.recover_job(job_id)
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, still_failed} = MirrorNeuron.inspect_job(job_id)
    assert still_failed["status"] == "failed"
    assert get_in(still_failed, ["result", "error"]) == "actual workflow failure"

    RedisStore.delete_job(job_id)
  end

  test "local recovery pauses unsafe in-progress steps for manual review" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "unsafe_recovery_review_test",
      "entrypoints" => ["writer"],
      "initial_inputs" => %{"writer" => [%{"value" => 99}]},
      "nodes" => [
        %{
          "node_id" => "writer",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => SafeRetryRunner,
            "side_effects" => "external",
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    restore_provenance = %{
      "source" => %{"job_id" => "backup-source-job", "run_id" => "source-run"},
      "target" => %{"run_id" => "restored-run"}
    }

    {:ok, job_id} =
      persist_recoverable_job(manifest, "unsafe-review", %{
        "restore_provenance" => restore_provenance
      })

    service_id = "unsafe-recovery-service-#{System.unique_integer([:positive])}"

    assert {:ok, _service} =
             ServiceRegistry.register(%{
               "id" => service_id,
               "name" => "unsafe-recovery-service",
               "job_id" => job_id,
               "node" => to_string(Node.self())
             })

    assert {:ok, %{action: :paused_for_review, reason: reason}} =
             MirrorNeuron.recover_job(job_id)

    assert reason =~ "do not declare retry safety"
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert get_in(job, ["recovery", "status"]) == "paused_for_review"
    assert job["restore_provenance"] == restore_provenance

    assert {:ok, []} = ServiceRegistry.list(job_id: job_id)

    assert {:ok, jobs} = MirrorNeuron.list_jobs(summary: :basic, include_terminal: false)
    summary = Enum.find(jobs, &(&1["job_id"] == job_id))
    assert summary["recovery_status"] == "paused_for_review"
    assert summary["recovery_requires_review"] == true

    assert {:ok, details} = MirrorNeuron.job_details(job_id)
    assert get_in(details, ["summary", "recovery", "status"]) == "paused_for_review"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_paused_for_review"))

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert completed["attempt"] == 1
    assert get_in(completed, ["result", "output", "payload", "value"]) == 99

    RedisStore.delete_job(job_id)
  end

  test "local recovery pauses visibly when recovery manifest is missing" do
    job_id = "#{Runtime.generate_job_id("missing_manifest_recovery_test")}-missing-manifest"

    {:ok, _job} =
      RedisStore.persist_job(job_id, %{
        "job_id" => job_id,
        "graph_id" => "missing_manifest_recovery_test",
        "job_name" => "missing_manifest_recovery_test",
        "status" => "running",
        "submitted_at" => Runtime.timestamp(),
        "updated_at" => Runtime.timestamp(),
        "root_agent_ids" => ["worker"],
        "placement_policy" => "local",
        "recovery_policy" => "local_restart",
        "result" => nil,
        "topology" => %{
          "nodes" => [
            %{
              "node_id" => "worker",
              "agent_type" => "executor",
              "type" => "generic",
              "role" => "root_coordinator"
            }
          ],
          "edges" => []
        },
        "manifest_ref" => %{}
      })

    assert {:error, reason} = MirrorNeuron.recover_job(job_id)
    assert reason =~ "missing_recovery_manifest"
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert job["recovery_status"] == "paused_for_review"
    assert job["recovery_reason"] =~ "missing_recovery_manifest"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_paused_for_review"))

    RedisStore.delete_job(job_id)
  end
end
