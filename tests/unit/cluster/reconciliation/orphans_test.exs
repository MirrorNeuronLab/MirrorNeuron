defmodule MirrorNeuron.Cluster.ReconcilerTest.OrphansTest do
  use MirrorNeuron.ReconciliationCase, async: false

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.ReconciliationCase.RedisStoreStub

  test "orphan sweep skips active job lease without persisting recovery eval" do
    job_id = unique_job_id("leased-job")
    job = running_job(job_id)
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_lease(job_id, %{"owner_id" => "coordinator@lab", "epoch" => 3})
    on_exit(fn -> RedisStoreStub.clear_lease(job_id) end)

    assert {:ok, result} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert result.checked == 1
    assert result.skipped == 1

    assert [%{job_id: ^job_id, action: :skipped, reason: "job lease is still active"}] =
             result.jobs

    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
  end

  test "orphan sweep delegates local restart jobs without creating a cluster recovery eval" do
    job_id = unique_job_id("orphan-job")

    job =
      running_job(job_id)
      |> Map.put("recovery_policy", "local_restart")
      |> Map.put("manifest", %{
        "graph_id" => "large-manifest",
        "payload" => String.duplicate("x", 1024)
      })

    RedisStoreStub.put_jobs([job])

    assert {:ok, result} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert result.checked == 1
    assert result.skipped == 1

    assert [%{job_id: ^job_id, action: :skipped, reason: "job is managed by local recovery"}] =
             result.jobs

    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
    refute_received {:job_persisted, ^job_id, _, _}
  end

  test "repeated orphan sweeps with active lease do not create eval churn" do
    job_id = unique_job_id("stable-lease-job")
    job = running_job(job_id)
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_lease(job_id, %{"owner_id" => "coordinator@lab", "epoch" => 4})
    on_exit(fn -> RedisStoreStub.clear_lease(job_id) end)

    assert {:ok, first} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)
    assert {:ok, second} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert first.skipped == 1
    assert second.skipped == 1
    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
  end

  test "repeated orphan sweeps do not reread or reevaluate jobs paused for review" do
    job_id = unique_job_id("paused-review-job")

    job =
      running_job(job_id)
      |> Map.merge(%{
        "status" => "paused",
        "recovery_status" => "paused_for_review",
        "recovery_requires_review" => true
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.raise_on_lease(job_id)
    RedisStoreStub.raise_on_fetch(job_id)

    on_exit(fn ->
      RedisStoreStub.clear_raise_on_lease(job_id)
      RedisStoreStub.clear_raise_on_fetch(job_id)
    end)

    assert {:ok, first} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)
    assert {:ok, second} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    for result <- [first, second] do
      assert result.checked == 1
      assert result.skipped == 1

      assert [%{job_id: ^job_id, action: :skipped, reason: "job is paused for review"}] =
               result.jobs
    end

    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
  end

  test "orphan sweep isolates per-job lease exceptions and continues" do
    crashing_job_id = unique_job_id("crashing-lease-job")
    stable_job_id = unique_job_id("stable-after-crash-job")

    RedisStoreStub.put_jobs([running_job(crashing_job_id), running_job(stable_job_id)])
    RedisStoreStub.raise_on_lease(crashing_job_id)
    RedisStoreStub.put_lease(stable_job_id, %{"owner_id" => "coordinator@lab", "epoch" => 8})

    on_exit(fn ->
      RedisStoreStub.clear_raise_on_lease(crashing_job_id)
      RedisStoreStub.clear_lease(stable_job_id)
    end)

    assert {:ok, result} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert result.checked == 2
    assert result.failed == 1
    assert result.skipped == 1

    failed_result = Enum.find(result.jobs, &(&1.job_id == crashing_job_id))
    assert failed_result.action == :failed
    assert failed_result.reason =~ "orphan sweep exception"
    assert failed_result.reason =~ "lease backend exploded"

    assert Enum.find(result.jobs, &(&1.job_id == stable_job_id)).action == :skipped
  end
end
