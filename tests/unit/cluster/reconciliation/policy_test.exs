defmodule MirrorNeuron.Cluster.ReconcilerTest.PolicyTest do
  use MirrorNeuron.ReconciliationCase, async: false

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.ReconciliationCase.RedisStoreStub
  alias MirrorNeuron.ReconciliationCase.EventBusStub
  alias MirrorNeuron.ReconciliationCase.CoordinatorStub

  test "pauses when reschedule policy is disabled" do
    {:ok, bundle} = JobBundle.load(manifest())

    job =
      running_job("policy-disabled")
      |> Map.put("reschedule_policy", %{
        "type" => "reschedule",
        "enabled" => true,
        "attempts" => 0,
        "interval_ms" => 86_400_000,
        "delay_ms" => 5_000,
        "delay_function" => "constant",
        "max_delay_ms" => 5_000,
        "unlimited" => false
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("policy-disabled", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "policy-disabled" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.paused == 1
    assert_receive {:job_persisted, "policy-disabled", updates, _}
    assert updates["status"] == "paused"
    assert updates["recovery_reason"] =~ "reschedule policy blocked"
    refute_received {:coordinator_rescheduled, _, _, _}
  end

  test "drain-triggered reschedule bypasses failure policy and does not consume attempts" do
    {:ok, bundle} = JobBundle.load(manifest())

    job =
      running_job("drain-policy-skip")
      |> Map.put("reschedule_policy", %{
        "type" => "reschedule",
        "enabled" => true,
        "attempts" => 0,
        "interval_ms" => 86_400_000,
        "delay_ms" => 5_000,
        "delay_function" => "constant",
        "max_delay_ms" => 5_000,
        "unlimited" => false
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("drain-policy-skip", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "drain-policy-skip" -> {:ok, coordinator} end,
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               trigger: "node_drain",
               skip_reschedule_policy: true,
               skip_reschedule_policy_record: true
             )

    assert result.recovered == 1
    assert_receive {:job_started, "drain-policy-skip", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]

    assert_receive {:job_persisted, "drain-policy-skip", %{"recovery_status" => "rescheduling"},
                    _}

    assert_receive {:job_persisted, "drain-policy-skip", %{"recovery_status" => "rescheduled"}, _}
    refute_received {:job_persisted, "drain-policy-skip", %{"policy_state" => _policy_state}, _}
  end

  test "blocks recovery when final plan validation sees stale target node" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("validation-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("validation-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    stale_large_node = Map.put(large_node(), "status", "offline")

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "validation-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               validation_nodes: [small_node(), stale_large_node],
               retry_base_ms: 10
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "validation-job", updates, _}
    assert updates["recovery_status"] == "blocked_no_placement"
    assert updates["recovery_reason"] =~ "offline"
    refute_received {:coordinator_rescheduled, _, _, _}
  end
end
