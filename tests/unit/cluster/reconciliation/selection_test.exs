defmodule MirrorNeuron.Cluster.ReconcilerTest.SelectionTest do
  use MirrorNeuron.ReconciliationCase, async: false

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.ReconciliationCase.RedisStoreStub
  alias MirrorNeuron.ReconciliationCase.EventBusStub
  alias MirrorNeuron.ReconciliationCase.CoordinatorStub

  test "does not relocate node-scoped system allocations to a different node" do
    job =
      running_job("system-job")
      |> Map.put("job_type", "system")
      |> put_in(["scheduler", "job_type"], "system")
      |> put_in(["scheduler", "system_targets"], ["small@lab", "large@lab"])
      |> put_in(["scheduler", "placements"], [
        %{
          "agent_id" => "worker@small@lab",
          "source_agent_id" => "worker",
          "agent_type" => "executor",
          "node" => "small@lab",
          "system_target" => "small@lab",
          "resources" => %{"cpu_cores" => 1, "memory_mb" => 512, "disk_mb" => 0, "gpu_count" => 0}
        },
        %{
          "agent_id" => "worker@large@lab",
          "source_agent_id" => "worker",
          "agent_type" => "executor",
          "node" => "large@lab",
          "system_target" => "large@lab",
          "resources" => %{"cpu_cores" => 1, "memory_mb" => 512, "disk_mb" => 0, "gpu_count" => 0}
        }
      ])

    RedisStoreStub.put_jobs([job])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               lookup_coordinator: fn "system-job" -> {:ok, coordinator} end
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "system-job", %{"recovery_status" => "waiting_for_node"}, _}
    assert_receive {:event_published, "system-job", %{type: :job_node_scoped_recovery_waiting}}
    refute_received {:coordinator_rescheduled, _, _, _}
  end

  test "pauses affected jobs that are not cluster recoverable" do
    job = running_job("local-job") |> Map.put("recovery_policy", "local_restart")
    RedisStoreStub.put_jobs([job])

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub
             )

    assert result.paused == 1
    assert_receive {:job_persisted, "local-job", updates, _}
    assert updates["status"] == "paused"
    assert updates["recovery_status"] == "paused_for_review"
  end

  test "only_job_ids limits node reconciliation to selected jobs" do
    RedisStoreStub.put_jobs([
      running_job("selected") |> Map.put("recovery_policy", "local_restart"),
      running_job("ignored") |> Map.put("recovery_policy", "local_restart")
    ])

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               only_job_ids: ["selected"]
             )

    assert result.checked == 1
    assert [%{job_id: "selected"}] = result.jobs
    assert_receive {:job_persisted, "selected", _, _}
    refute_receive {:job_persisted, "ignored", _, _}
  end

  test "node reconciliation skips unaffected summaries without fetching full jobs" do
    job_id = unique_job_id("unaffected-job")
    job = running_job(job_id)
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.raise_on_fetch(job_id)

    on_exit(fn -> RedisStoreStub.clear_raise_on_fetch(job_id) end)

    assert {:ok, result} =
             Reconciler.reconcile_node("other@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub
             )

    assert result.checked == 1
    assert result.skipped == 1
    assert [%{job_id: ^job_id, action: :skipped}] = result.jobs
  end

  test "node reconciliation does not load paused-for-review job snapshots" do
    job_id = unique_job_id("paused-node-job")

    job =
      running_job(job_id)
      |> Map.merge(%{
        "status" => "paused",
        "recovery_status" => "paused_for_review",
        "recovery_requires_review" => true
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.raise_on_fetch(job_id)
    on_exit(fn -> RedisStoreStub.clear_raise_on_fetch(job_id) end)

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub
             )

    assert result.checked == 1
    assert result.skipped == 1

    assert [%{job_id: ^job_id, action: :skipped, reason: "job is paused for review"}] =
             result.jobs

    refute_received {:job_persisted, ^job_id, _, _}
    refute_received {:event_published, ^job_id, _}
  end
end
