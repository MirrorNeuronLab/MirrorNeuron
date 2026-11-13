defmodule MirrorNeuron.Persistence.RedisStore.RecoveryTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  test "recovery evals can be listed by active status" do
    # Listing is independent of retention. Keep terminal fixtures current so
    # the application retention worker cannot legitimately expire them.
    now = DateTime.utc_now()
    pending_created = now |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    complete_created = DateTime.to_iso8601(now)
    pending_id = "pending-eval-#{System.unique_integer([:positive])}"
    complete_id = "complete-eval-#{System.unique_integer([:positive])}"

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(pending_id, %{
               "status" => "pending",
               "created_at" => pending_created
             })

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(complete_id, %{
               "status" => "complete",
               "created_at" => complete_created
             })

    assert {:ok, pending_evals} = RedisStore.list_recovery_evals(["pending", "blocked"])
    assert Enum.map(pending_evals, & &1["eval_id"]) == [pending_id]

    assert {:ok, complete_evals} = RedisStore.list_recovery_evals(["complete"])
    assert Enum.map(complete_evals, & &1["eval_id"]) == [complete_id]

    assert {:ok, _eval} =
             RedisStore.update_recovery_eval(pending_id, %{
               "status" => "complete",
               "completed_at" => Runtime.timestamp()
             })

    assert {:ok, []} = RedisStore.list_recovery_evals(["pending", "blocked"])
    assert {:ok, complete_evals} = RedisStore.list_recovery_evals(["complete"])
    assert Enum.map(complete_evals, & &1["eval_id"]) == [pending_id, complete_id]
  end

  test "repair_recovery_indexes rebuilds recovery eval status indexes", %{namespace: namespace} do
    eval_id = "legacy-eval-#{System.unique_integer([:positive])}"

    eval = %{
      "eval_id" => eval_id,
      "status" => "blocked",
      "created_at" => "2026-01-01T00:00:00Z"
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["recovery", "eval", eval_id]),
               Jason.encode!(eval)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals"]),
               eval_id
             ])

    assert {:ok, []} = RedisStore.list_recovery_evals(["blocked"])

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.repaired_recovery_evals == 1

    assert {:ok, [repaired]} = RedisStore.list_recovery_evals(["blocked"])
    assert repaired["eval_id"] == eval_id
  end

  test "terminal recovery evals receive ttl and active evals persist", %{namespace: namespace} do
    System.put_env("MN_RECOVERY_EVAL_TTL_SECONDS", "120")
    complete_id = "ttl-complete-eval-#{System.unique_integer([:positive])}"
    pending_id = "ttl-pending-eval-#{System.unique_integer([:positive])}"

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(complete_id, %{
               "job_id" => "job-a",
               "status" => "complete"
             })

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(pending_id, %{
               "job_id" => "job-a",
               "status" => "pending"
             })

    assert {:ok, complete_ttl} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "TTL",
               redis_key(namespace, ["recovery", "eval", complete_id])
             ])

    assert complete_ttl > 0
    assert complete_ttl <= 120

    assert {:ok, -1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "TTL",
               redis_key(namespace, ["recovery", "eval", pending_id])
             ])
  end

  test "retention sweep does not renew terminal recovery eval ttl", %{namespace: namespace} do
    System.put_env("MN_RECOVERY_EVAL_TTL_SECONDS", "120")
    eval_id = "ttl-not-renewed-eval-#{System.unique_integer([:positive])}"
    eval_key = redis_key(namespace, ["recovery", "eval", eval_id])

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(eval_id, %{
               "job_id" => "job-a",
               "status" => "complete"
             })

    assert {:ok, 1} = Redix.command(MirrorNeuron.Redis.Connection, ["EXPIRE", eval_key, "30"])
    assert {:ok, _result} = RedisStore.sweep_retention()
    assert {:ok, ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", eval_key])
    assert ttl in 1..30
  end

  test "retention sweep removes expired recovery evals and stale index ids",
       %{namespace: namespace} do
    old_eval_id = "expired-eval-#{System.unique_integer([:positive])}"
    stale_eval_id = "stale-eval-#{System.unique_integer([:positive])}"
    status_only_eval_id = "status-only-eval-#{System.unique_integer([:positive])}"

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(old_eval_id, %{
               "job_id" => "job-a",
               "status" => "complete",
               "updated_at" => "2026-01-01T00:00:00Z"
             })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals"]),
               stale_eval_id
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals", "status", "complete"]),
               stale_eval_id
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals", "status", "failed"]),
               status_only_eval_id
             ])

    System.put_env("MN_RECOVERY_EVAL_TTL_SECONDS", "0")

    assert {:ok, result} = RedisStore.sweep_retention()
    assert old_eval_id in result.deleted_recovery_evals
    assert stale_eval_id in result.stale_recovery_evals
    assert status_only_eval_id in result.stale_recovery_evals
    assert {:error, _reason} = RedisStore.fetch_recovery_eval(old_eval_id)

    for {status, eval_id} <- [
          {"complete", old_eval_id},
          {"complete", stale_eval_id},
          {"failed", status_only_eval_id}
        ] do
      assert {:ok, 0} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SISMEMBER",
                 redis_key(namespace, ["recovery", "evals", "status", status]),
                 eval_id
               ])
    end
  end

  test "retention preserves unreadable recovery evals for explicit repair", %{
    namespace: namespace
  } do
    eval_id = "unreadable-eval-#{System.unique_integer([:positive])}"
    recovery = Process.whereis(MirrorNeuron.Runtime.LocalRecovery)

    if recovery, do: :sys.suspend(recovery)

    on_exit(fn ->
      if recovery && Process.alive?(recovery), do: :sys.resume(recovery)
    end)

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["recovery", "eval", eval_id]),
               "not-json"
             ])

    for key_parts <- [
          ["recovery", "evals"],
          ["recovery", "evals", "status", "complete"]
        ] do
      assert {:ok, 1} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SADD",
                 redis_key(namespace, key_parts),
                 eval_id
               ])
    end

    assert {:ok, result} = RedisStore.sweep_retention()
    refute eval_id in result.stale_recovery_evals
    refute eval_id in result.deleted_recovery_evals

    assert {:ok, "not-json"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["recovery", "eval", eval_id])
             ])
  end

  test "repair_recovery_indexes makes job control records discoverable and removes stale jobs",
       %{namespace: namespace} do
    job_id = "repair-job-#{System.unique_integer([:positive])}"
    stale_job_id = "stale-job-#{System.unique_integer([:positive])}"

    job = %{
      "job_id" => job_id,
      "status" => "running",
      "graph_id" => "repair_index_test",
      "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id]),
               Jason.encode!(job)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               stale_job_id
             ])

    assert {:ok, jobs_before} = RedisStore.list_jobs()
    refute Enum.any?(jobs_before, &(&1["job_id"] == job_id))

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.repaired_jobs == 1
    assert result.repaired_agents == 0
    assert result.removed_stale_jobs == 1
    assert result.removed_stale_agents == 0

    assert {:ok, jobs_after} = RedisStore.list_jobs()
    assert Enum.any?(jobs_after, &(&1["job_id"] == job_id))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["jobs"]),
               stale_job_id
             ])

    RedisStore.delete_job(job_id)
  end

  test "repair_recovery_indexes removes corrupt indexed job control records", %{
    namespace: namespace
  } do
    corrupt_job_id = "corrupt-job-#{System.unique_integer([:positive])}"
    job_id = "valid-job-#{System.unique_integer([:positive])}"

    job = %{
      "job_id" => job_id,
      "status" => "running",
      "graph_id" => "corrupt_index_repair_test",
      "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", corrupt_job_id]),
               "{not-json"
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               corrupt_job_id
             ])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id]),
               Jason.encode!(job)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               job_id
             ])

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.removed_stale_jobs == 1
    assert result.removed_stale_agents == 0

    assert {:ok, jobs} = RedisStore.list_jobs()
    refute Enum.any?(jobs, &(&1["job_id"] == corrupt_job_id))
    assert Enum.any?(jobs, &(&1["job_id"] == job_id))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["jobs"]),
               corrupt_job_id
             ])
  end

  test "recovery evals can be persisted, listed, and updated" do
    eval_id = "eval-#{System.unique_integer([:positive])}"

    assert {:ok, eval} =
             RedisStore.persist_recovery_eval(eval_id, %{
               "job_id" => "job-a",
               "trigger" => "node_down",
               "status" => "pending",
               "attempt" => 0,
               "affected_agents" => ["worker"],
               "job" => %{
                 "job_id" => "job-a",
                 "manifest" => %{"payload" => String.duplicate("x", 1024)}
               },
               "manifest" => %{"payload" => String.duplicate("y", 1024)},
               "runtime_logs" => ["noisy runtime line"]
             })

    assert eval["eval_id"] == eval_id
    assert eval["status"] == "pending"
    refute Map.has_key?(eval, "job")
    refute Map.has_key?(eval, "manifest")
    refute Map.has_key?(eval, "runtime_logs")

    assert {:ok, fetched} = RedisStore.fetch_recovery_eval(eval_id)
    assert fetched["affected_agents"] == ["worker"]
    refute Map.has_key?(fetched, "job")
    refute Map.has_key?(fetched, "manifest")
    refute Map.has_key?(fetched, "runtime_logs")

    assert {:ok, evals} = RedisStore.list_recovery_evals()
    assert Enum.any?(evals, &(&1["eval_id"] == eval_id))

    assert {:ok, updated} =
             RedisStore.update_recovery_eval(eval_id, %{
               "status" => "blocked",
               "wait_until" => "2030-01-01T00:00:00Z"
             })

    assert updated["status"] == "blocked"
    assert updated["wait_until"] == "2030-01-01T00:00:00Z"
    refute Map.has_key?(updated, "job")
  end
end
