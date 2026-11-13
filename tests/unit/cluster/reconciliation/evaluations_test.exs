defmodule MirrorNeuron.Cluster.ReconcilerTest.EvaluationsTest do
  use MirrorNeuron.ReconciliationCase, async: false

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.ReconciliationCase.RedisStoreStub
  alias MirrorNeuron.ReconciliationCase.EventBusStub
  alias MirrorNeuron.ReconciliationCase.CoordinatorStub

  test "blocks recovery eval when no alternate placement exists" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("blocked-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("blocked-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "blocked-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node()], jobs: [job]],
               retry_base_ms: 10
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "blocked-job", updates, _}
    assert updates["recovery_status"] == "blocked_no_placement"
    assert updates["recovery_wait_until"]
    refute_received {:job_persisted, "blocked-job", %{"policy_state" => _policy_state}, _}
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "blocked"
    assert eval["attempt"] == 1
    refute_received {:coordinator_rescheduled, _, _, _}
  end

  test "due eval sweep ignores completed recovery eval history" do
    RedisStoreStub.put_evals([
      %{
        "eval_id" => "complete-eval",
        "job_id" => "finished-job",
        "trigger" => "lease_lost",
        "status" => "complete",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z",
        "job" => running_job("finished-job")
      }
    ])

    assert {:ok, result} = Reconciler.process_due_evals(redis_store: RedisStoreStub)
    assert result.checked == 0
    assert result.skipped == 0
  end

  test "due eval sweep marks eval failed when processing raises" do
    job_id = unique_job_id("eval-fetch-crash-job")
    eval_id = "eval-fetch-crash"

    RedisStoreStub.put_evals([
      %{
        "eval_id" => eval_id,
        "job_id" => job_id,
        "trigger" => "lease_lost",
        "status" => "pending",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z"
      }
    ])

    RedisStoreStub.raise_on_fetch(job_id)
    on_exit(fn -> RedisStoreStub.clear_raise_on_fetch(job_id) end)

    assert {:ok, result} = Reconciler.process_due_evals(redis_store: RedisStoreStub)

    assert result.checked == 1
    assert result.failed == 1
    assert [%{job_id: ^job_id, action: :failed, reason: reason}] = result.jobs
    assert reason =~ "recovery eval #{eval_id} exception"
    assert reason =~ "fetch backend exploded"

    assert_receive {:eval_persisted, ^eval_id, %{"status" => "running"}}
    assert_receive {:eval_persisted, ^eval_id, %{"status" => "failed"} = failed_eval}
    assert failed_eval["completed_at"]
    assert [%{"status" => "failed", "reason" => failed_reason}] = failed_eval["history"]
    assert failed_reason =~ "fetch backend exploded"
  end

  test "waits during disconnected grace window" do
    job = running_job("grace-job")
    RedisStoreStub.put_jobs([job])
    wait_until = future_iso(60_000)

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               node_status: "disconnected",
               wait_until: wait_until
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "grace-job", updates, _}
    assert updates["recovery_status"] == "waiting_for_node"
    assert updates["recovery_wait_until"] == wait_until
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "blocked"
    assert eval["wait_until"] == wait_until
  end

  test "offline recovery reuses the disconnected grace eval" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("grace-recover-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("grace-recover-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, blocked_result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               node_status: "disconnected",
               wait_until: future_iso(60_000)
             )

    assert blocked_result.blocked == 1

    assert {:ok, [%{"eval_id" => eval_id, "status" => "blocked"}]} =
             RedisStoreStub.list_recovery_evals()

    assert {:ok, recovered_result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               node_status: "offline",
               force: true,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "grace-recover-job" -> {:ok, coordinator} end,
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert recovered_result.recovered == 1
    assert_receive {:job_started, "grace-recover-job", opts}
    assert opts[:preferred_start_node] == "large@lab"

    assert {:ok, [%{"eval_id" => ^eval_id, "status" => "complete"}]} =
             RedisStoreStub.list_recovery_evals()
  end

  test "wakes blocked evals after new capacity appears" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("wake-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("wake-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, blocked_result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "wake-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node()], jobs: [job]],
               retry_base_ms: 10
             )

    assert blocked_result.blocked == 1

    assert {:ok, wake_result} =
             Reconciler.wake_blocked_evals(
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "wake-job" -> {:ok, coordinator} end,
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               retry_base_ms: 10,
               reason: "node joined"
             )

    assert wake_result.recovered == 1
    assert_receive {:job_started, "wake-job", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "complete"
    assert eval["attempt"] == 2
  end

  test "GPU recovery stays blocked on CPU-only nodes and resumes on a rejoined GPU node with a new name" do
    {:ok, bundle} = JobBundle.load(gpu_manifest())

    job =
      running_job("gpu-wake-job")
      |> put_in(["scheduler", "placements"], [
        %{
          "agent_id" => "worker",
          "agent_type" => "executor",
          "node" => "gpu-old@lab",
          "resources" => %{
            "cpu_cores" => 1,
            "memory_mb" => 512,
            "disk_mb" => 0,
            "gpu_count" => 1
          },
          "allocations" => %{
            "devices" => [%{"id" => "cuda-0", "driver" => "cuda"}]
          }
        }
      ])

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("gpu-wake-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, blocked_result} =
             Reconciler.reconcile_node("gpu-old@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "gpu-wake-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               retry_base_ms: 10
             )

    assert blocked_result.blocked == 1
    assert_receive {:job_persisted, "gpu-wake-job", blocked_updates, _}
    assert blocked_updates["recovery_status"] == "blocked_no_placement"
    refute_received {:coordinator_rescheduled, _, _, _}

    assert {:ok, wake_result} =
             Reconciler.wake_blocked_evals(
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "gpu-wake-job" -> {:ok, coordinator} end,
               start_job_runner: job_starter(self()),
               scheduler_opts: [
                 nodes: [small_node(), gpu_rejoin_node("gpu-new@lab")],
                 jobs: [job]
               ],
               retry_base_ms: 10,
               reason: "gpu node rejoined"
             )

    assert wake_result.recovered == 1
    assert_receive {:job_started, "gpu-wake-job", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert opts[:restart_reason] =~ "node gpu-old@lab is unavailable"
    assert [%{"agent_id" => "worker", "node" => "gpu-new@lab"}] = scheduler_plan["placements"]

    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "complete"
    assert eval["attempt"] == 2
    assert eval["wake_reason"] == "gpu node rejoined"
  end
end
