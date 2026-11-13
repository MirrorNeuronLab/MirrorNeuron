defmodule MirrorNeuron.Persistence.RedisStore.JobsTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore

  test "terminal intent recovers without replaying work or duplicating its event" do
    job_id = "finalization-#{System.unique_integer([:positive])}"
    pending = %{"job_id" => job_id, "status" => "running", "attempt" => 1, "lease_epoch" => 3}
    terminal = Map.put(pending, "status", "completed")
    assert {:ok, _} = RedisStore.persist_job(job_id, pending)

    assert {:error, :interrupted} =
             MirrorNeuron.Runtime.Finalization.commit(
               job_id,
               pending,
               terminal,
               %{type: :job_completed},
               finish: fn _, _, _ -> {:error, :interrupted} end
             )

    assert {:ok, stored} = RedisStore.fetch_job(job_id)
    assert stored["status"] == "running"
    assert is_map(stored["pending_finalization"])

    assert {:ok, %{reason: "terminal finalization recovered"}} =
             MirrorNeuron.Runtime.LocalRecovery.recover_job(job_id)

    assert Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) == []
    assert {:ok, _} = MirrorNeuron.Runtime.Finalization.recover(stored)
    assert {:ok, completed} = RedisStore.fetch_job(job_id)
    assert completed["status"] == "completed"
    refute Map.has_key?(completed, "pending_finalization")
    assert {:ok, [event]} = RedisStore.read_events(job_id)
    assert event["type"] == "job_completed"
    assert event["event_id"] == completed["finalization_id"]
    RedisStore.delete_job(job_id)
  end

  test "stable job definitions never collide with run records" do
    stable_job_id = "job-stable-#{System.unique_integer([:positive])}"
    run_id = "run-#{System.unique_integer([:positive])}"

    assert {:ok, definition} =
             RedisStore.persist_job_definition(stable_job_id, %{
               "status" => "active",
               "run_ids" => [run_id],
               "data_generation" => 1
             })

    assert definition["job_id"] == stable_job_id

    assert {:ok, _run} =
             RedisStore.persist_job(run_id, %{"job_id" => run_id, "status" => "pending"})

    assert {:ok, fetched_definition} = RedisStore.fetch_job_definition(stable_job_id)
    assert fetched_definition["run_ids"] == [run_id]
    assert {:ok, fetched_run} = RedisStore.fetch_job(run_id)
    assert fetched_run["job_id"] == run_id
    assert {:ok, definitions} = RedisStore.list_job_definitions()
    assert Enum.any?(definitions, &(&1["job_id"] == stable_job_id))

    assert :ok = RedisStore.delete_job_definition(stable_job_id)
    assert {:ok, _run} = RedisStore.fetch_job(run_id)
    assert :ok = RedisStore.delete_job(run_id)
  end

  test "job guards keep lifecycle checks independent of large workflow state", %{
    namespace: namespace
  } do
    job_id = "compact-job-guard-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => 7,
               "updated_at" => "2026-07-19T12:00:00Z",
               "workflow_state" => %{"payload" => String.duplicate("x", 500_000)}
             })

    full_key = redis_key(namespace, ["job", job_id])
    guard_key = redis_key(namespace, ["job", job_id, "guard"])

    assert {:ok, encoded_guard} =
             Redix.command(MirrorNeuron.Redis.Connection, ["GET", guard_key])

    assert {:ok,
            %{
              "job_id" => ^job_id,
              "status" => "running",
              "lease_epoch" => 7,
              "updated_at" => "2026-07-19T12:00:00Z"
            }} = Jason.decode(encoded_guard)

    assert {:ok, full_bytes} = Redix.command(MirrorNeuron.Redis.Connection, ["STRLEN", full_key])
    assert byte_size(encoded_guard) < div(full_bytes, 100)

    RedisStore.delete_job(job_id)
  end

  test "job projections update monitoring without rewriting the durable snapshot", %{
    namespace: namespace
  } do
    job_id = "job-projection-#{System.unique_integer([:positive])}"

    durable = %{
      "job_id" => job_id,
      "status" => "running",
      "lease_epoch" => 3,
      "lease" => %{"owner_id" => "runtime@lab", "epoch" => 3},
      "updated_at" => "2026-07-19T12:00:00Z",
      "scheduler" => %{
        "status" => "scheduled",
        "job_type" => "batch",
        "placement_count" => 2,
        "placements" => [
          %{
            "agent_id" => "first",
            "node" => "runtime@lab",
            "diagnostics" => String.duplicate("x", 50_000)
          },
          %{"agent_id" => "second", "node" => "runtime@lab"}
        ]
      },
      "workflow_state" => %{"durable_marker" => "first"}
    }

    projection =
      durable
      |> Map.put("updated_at", "2026-07-19T12:00:30Z")
      |> Map.put("workflow_state", %{"durable_marker" => "projected-only"})

    assert {:ok, durable} = RedisStore.persist_job(job_id, durable)
    assert {:ok, _projection} = RedisStore.persist_job_projection(job_id, projection)
    assert {:ok, ^durable} = RedisStore.fetch_job(job_id)

    assert {:ok, summaries} = RedisStore.list_job_summaries()

    summary = Enum.find(summaries, &(&1["job_id"] == job_id))
    assert %{"updated_at" => "2026-07-19T12:00:30Z"} = summary
    assert summary["lease_owner"] == "runtime@lab"
    assert summary["scheduler"]["nodes"] == ["runtime@lab"]
    assert summary["scheduler"]["placement_count"] == 2
    refute Map.has_key?(summary["scheduler"], "placements")

    summary_key = redis_key(namespace, ["job", job_id, "summary"])

    assert {:ok, encoded_summary} =
             Redix.command(MirrorNeuron.Redis.Connection, ["GET", summary_key])

    assert byte_size(encoded_summary) < 5_000

    guard_key = redis_key(namespace, ["job", job_id, "guard"])
    assert {:ok, encoded_guard} = Redix.command(MirrorNeuron.Redis.Connection, ["GET", guard_key])
    assert {:ok, %{"updated_at" => "2026-07-19T12:00:30Z"}} = Jason.decode(encoded_guard)

    RedisStore.delete_job(job_id)
  end

  test "active job snapshots persist until the job becomes terminal", %{namespace: namespace} do
    Application.put_env(:mirror_neuron, :agent_snapshot_ttl_seconds, 120)
    job_id = "active-snapshot-retention-#{System.unique_integer([:positive])}"
    agent_id = "worker"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "active_snapshot_retention",
               "status" => "paused",
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, _agent} =
             RedisStore.persist_agent(job_id, agent_id, %{
               "agent_id" => agent_id,
               "last_heartbeat_at" => MirrorNeuron.Runtime.timestamp()
             })

    agent_key = redis_key(namespace, ["job", job_id, "agent", agent_id])
    agents_key = redis_key(namespace, ["job", job_id, "agents"])

    assert {:ok, -1} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agent_key])
    assert {:ok, -1} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agents_key])

    assert {:ok, _job} = RedisStore.persist_terminal_job(job_id, %{"status" => "completed"})

    assert {:ok, agent_ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agent_key])
    assert {:ok, agents_ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agents_key])
    assert agent_ttl in 1..120
    assert agents_ttl > 0

    RedisStore.delete_job(job_id)
  end

  test "list_job_summaries returns compact records" do
    job_id = "summary-job-#{System.unique_integer([:positive])}"
    large_payload = String.duplicate("x", 64_000)

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "summary_demo",
               "status" => "running",
               "submitted_at" => "2026-03-28T00:00:00Z",
               "updated_at" => "2026-03-28T00:00:10Z",
               "manifest" => %{"payload" => large_payload},
               "workflow" => %{"payload" => large_payload}
             })

    assert {:ok, [summary]} = RedisStore.list_job_summaries()
    assert summary["job_id"] == job_id
    assert summary["graph_id"] == "summary_demo"
    refute Map.has_key?(summary, "manifest")
    refute Map.has_key?(summary, "workflow")

    RedisStore.delete_job(job_id)
  end

  test "list_job_summaries flags recoverable runner interruptions" do
    job_id = "summary-failed-runner-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "summary_failed_runner",
               "status" => "failed",
               "submitted_at" => "2026-03-28T00:00:00Z",
               "updated_at" => "2026-03-28T00:00:10Z",
               "result" => %{
                 "agent_id" => "job_runner",
                 "error" => "job coordinator exited before terminal state",
                 "reason" => ":normal"
               }
             })

    assert {:ok, [summary]} = RedisStore.list_job_summaries()
    assert summary["job_id"] == job_id
    assert summary["status"] == "failed"
    assert summary["recovery_hint"] == "runner_interruption"

    assert summary["failure"] == %{
             "agent_id" => "job_runner",
             "message" => "job coordinator exited before terminal state"
           }

    refute Map.has_key?(summary, "result")

    RedisStore.delete_job(job_id)
  end

  test "failed job summaries retain bounded structured diagnostics" do
    job_id = "summary-failed-bootstrap-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "summary_failed_bootstrap",
               "status" => "failed",
               "result" => %{
                 "error" => %{
                   "category" => "timeout",
                   "component" => "job_coordinator",
                   "message" => "failed to start agent audit__end: :timeout",
                   "agent_id" => "audit__end",
                   "node" => "mirror_neuron@10.0.4.27",
                   "retryable" => true,
                   "details" => String.duplicate("not-in-summary", 10_000)
                 }
               }
             })

    assert {:ok, [summary]} = RedisStore.list_job_summaries()

    assert summary["failure"] == %{
             "agent_id" => "audit__end",
             "category" => "timeout",
             "component" => "job_coordinator",
             "message" => "failed to start agent audit__end: :timeout",
             "node" => "mirror_neuron@10.0.4.27",
             "retryable" => true
           }

    refute Map.has_key?(summary["failure"], "details")
    RedisStore.delete_job(job_id)
  end
end
