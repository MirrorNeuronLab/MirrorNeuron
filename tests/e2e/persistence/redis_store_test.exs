defmodule MirrorNeuron.Persistence.RedisStoreTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Bundle.{Archive, Fingerprint}
  alias MirrorNeuron.Artifacts.JobStore
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.ServiceRegistry

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> raise "Redis must be running for redis store tests"
    end

    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_event_max_count = Application.get_env(:mirror_neuron, :event_max_count)
    old_terminal_ttl = Application.get_env(:mirror_neuron, :terminal_job_ttl_seconds)
    old_recovery_eval_ttl = Application.get_env(:mirror_neuron, :recovery_eval_ttl_seconds)
    old_system_recovery_eval_ttl = System.get_env("MN_RECOVERY_EVAL_TTL_SECONDS")
    old_wait_replicas = Application.get_env(:mirror_neuron, :redis_wait_replicas)
    old_wait_timeout = Application.get_env(:mirror_neuron, :redis_wait_timeout_ms)

    namespace = "mirror_neuron_test_#{System.unique_integer([:positive])}"
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    Application.put_env(:mirror_neuron, :redis_wait_replicas, 0)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 100)

    on_exit(fn ->
      cleanup_namespace(namespace)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_env(:redis_namespace, old_namespace)
      restore_env(:event_max_count, old_event_max_count)
      restore_env(:terminal_job_ttl_seconds, old_terminal_ttl)
      restore_env(:recovery_eval_ttl_seconds, old_recovery_eval_ttl)
      restore_system_env("MN_RECOVERY_EVAL_TTL_SECONDS", old_system_recovery_eval_ttl)
      restore_env(:redis_wait_replicas, old_wait_replicas)
      restore_env(:redis_wait_timeout_ms, old_wait_timeout)
    end)

    {:ok, namespace: namespace}
  end

  test "append_event trims old events using configured retention" do
    Application.put_env(:mirror_neuron, :event_max_count, 3)
    job_id = "event-retention-#{System.unique_integer([:positive])}"

    for seq <- 1..5 do
      assert {:ok, _event} = RedisStore.append_event(job_id, %{"type" => "test", "seq" => seq})
    end

    assert {:ok, events} = RedisStore.read_events(job_id)
    assert Enum.map(events, & &1["seq"]) == [3, 4, 5]

    RedisStore.delete_job(job_id)
  end

  test "persists deployments and immutable version records" do
    deployment_id = "dep-test-#{System.unique_integer([:positive])}"
    deployment_key = "agent-api"

    assert {:ok, deployment} =
             RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => deployment_key,
               "status" => "successful",
               "current_version" => "1"
             })

    assert deployment["deployment_id"] == deployment_id
    assert {:ok, fetched} = RedisStore.fetch_deployment(deployment_id)
    assert fetched["deployment_key"] == deployment_key
    assert {:ok, fetched_by_key} = RedisStore.fetch_deployment_by_key(deployment_key)
    assert fetched_by_key["deployment_id"] == deployment_id

    assert {:ok, version} =
             RedisStore.persist_job_version(deployment_key, "1", %{
               "job_id" => "job-1",
               "manifest" => %{"graph_id" => "agent-api"},
               "stable" => true
             })

    assert version["version"] == "1"
    assert {:ok, fetched_version} = RedisStore.fetch_job_version(deployment_key, "1")
    assert fetched_version["job_id"] == "job-1"
    assert {:ok, [listed_version]} = RedisStore.list_job_versions(deployment_key)
    assert listed_version["stable"] == true
  end

  test "service discovery hides deployment candidates until promoted" do
    assert {:ok, _service} =
             ServiceRegistry.register(%{
               "id" => "svc-candidate",
               "name" => "agent-api",
               "status" => "passing",
               "deployment_key" => "agent-api",
               "deployment_version" => "2",
               "deployment_role" => "canary"
             })

    assert {:ok, []} = ServiceRegistry.resolve("agent-api")
    assert {:ok, [candidate]} = ServiceRegistry.resolve("agent-api", include_candidates: true)
    assert candidate["deployment_role"] == "canary"

    assert {:ok, [_promoted]} = ServiceRegistry.promote_deployment("agent-api", "2")
    assert {:ok, [primary]} = ServiceRegistry.resolve("agent-api")
    assert primary["deployment_role"] == "primary"
  end

  test "read_events can fetch a bounded recent window" do
    job_id = "event-window-#{System.unique_integer([:positive])}"

    for seq <- 1..5 do
      assert {:ok, _event} = RedisStore.append_event(job_id, %{"type" => "test", "seq" => seq})
    end

    assert {:ok, events} = RedisStore.read_events(job_id, -2, -1)
    assert Enum.map(events, & &1["seq"]) == [4, 5]

    RedisStore.delete_job(job_id)
  end

  test "event bus publish persists once and still dispatches to subscribers" do
    job_id = "event-bus-#{System.unique_integer([:positive])}"

    assert {:ok, _} = EventBus.subscribe(job_id)
    assert :ok = EventBus.publish(job_id, %{type: :test_event, payload: %{value: 1}})

    assert_receive {:mirror_neuron_event,
                    %{type: :test_event, payload: %{value: 1}, job_id: ^job_id}},
                   500

    assert {:ok, [%{"type" => "test_event", "payload" => %{"value" => 1}}]} =
             RedisStore.read_events(job_id)

    RedisStore.delete_job(job_id)
  end

  test "event persistence errors stay local and event bus sanitizes runtime diagnostics" do
    bad_job_id = "bad-event-#{System.unique_integer([:positive])}"
    job_id = "safe-event-bus-#{System.unique_integer([:positive])}"
    callback = fn -> :ok end

    assert {:error, _reason} =
             RedisStore.append_event(bad_job_id, %{
               "type" => "bad",
               "callback" => callback
             })

    assert {:ok, _} = EventBus.subscribe(job_id)

    assert :ok =
             EventBus.publish(job_id, %{
               type: :runtime_diagnostic,
               payload: %{
                 callback: callback,
                 owner: self(),
                 tuple: {:runtime, 1},
                 status: :ok
               }
             })

    assert_receive {:mirror_neuron_event,
                    %{
                      type: :runtime_diagnostic,
                      payload: %{callback: received_callback, owner: owner}
                    }},
                   500

    assert is_function(received_callback, 0)
    assert owner == self()

    assert {:ok, [stored]} = RedisStore.read_events(job_id)
    assert stored["type"] == "runtime_diagnostic"
    assert stored["payload"]["callback"] =~ "#Function"
    assert stored["payload"]["owner"] =~ "#PID"
    assert stored["payload"]["tuple"] == "{:runtime, 1}"
    assert stored["payload"]["status"] == "ok"
  end

  test "service registry persists, resolves passing instances, and deregisters by agent" do
    job_id = "service-registry-#{System.unique_integer([:positive])}"

    passing = %{
      "id" => "#{job_id}:worker:ollama",
      "name" => "ollama",
      "job_id" => job_id,
      "agent_id" => "worker",
      "node" => "gpu@lab",
      "address" => "127.0.0.1",
      "port" => 11_434,
      "tags" => ["gpu"],
      "status" => "passing"
    }

    critical =
      passing
      |> Map.put("id", "#{job_id}:other:ollama")
      |> Map.put("agent_id", "other")
      |> Map.put("node", "cpu@lab")
      |> Map.put("status", "critical")

    assert {:ok, _} = ServiceRegistry.register(passing)
    assert {:ok, _} = ServiceRegistry.register(critical)

    assert {:ok, [resolved]} = ServiceRegistry.resolve("ollama", tags: ["gpu"])
    assert resolved["id"] == passing["id"]
    assert resolved["status"] == "passing"

    assert {:ok, all} = ServiceRegistry.list(name: "ollama", passing_only: false)
    assert Enum.count(all, &(&1["job_id"] == job_id)) == 2

    assert ServiceRegistry.requirements_satisfied_on_node?(
             [%{"name" => "ollama", "tags" => ["gpu"]}],
             "gpu@lab"
           )

    refute ServiceRegistry.requirements_satisfied_on_node?(
             [%{"name" => "ollama", "tags" => ["gpu"]}],
             "cpu@lab"
           )

    assert :ok = ServiceRegistry.deregister_agent(job_id, "worker")
    assert {:ok, []} = ServiceRegistry.resolve("ollama", tags: ["gpu"])

    assert :ok = ServiceRegistry.deregister_job(job_id)
  end

  test "retention sweep deletes expired terminal jobs and stale job ids" do
    job_id = "terminal-retention-#{System.unique_integer([:positive])}"
    old_job_root = System.get_env("MN_JOB_ARTIFACT_ROOT")

    job_root =
      Path.join(System.tmp_dir!(), "mn_job_artifacts_#{System.unique_integer([:positive])}")

    System.put_env("MN_JOB_ARTIFACT_ROOT", job_root)

    on_exit(fn ->
      restore_system_env("MN_JOB_ARTIFACT_ROOT", old_job_root)
      File.rm_rf(job_root)
    end)

    assert {:ok, job_path} = JobStore.ensure_job_dir(job_id)
    File.write!(Path.join(job_path, "artifact.txt"), "done")

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(job_id, %{"status" => "completed"}, %{
               "graph_id" => "retention_test",
               "job_name" => "retention_test"
             })

    assert {:ok, _job} = RedisStore.fetch_job(job_id)

    assert {:ok, result} = RedisStore.sweep_retention(terminal_job_ttl_seconds: 0)
    assert result.deleted_jobs == [job_id]
    assert result.deleted_count == 1
    assert {:error, _reason} = RedisStore.fetch_job(job_id)
    refute File.exists?(job_path)
  end

  test "register_blob_ref persists shared filesystem locations without urls" do
    sha256 = String.duplicate("d", 64)
    path = Path.join(binary_part(sha256, 0, 2), sha256)

    ref = %{
      "type" => "blob_ref",
      "sha256" => sha256,
      "locations" => [
        %{
          "node" => "node-a@lab",
          "storage" => "shared_fs",
          "root" => "blob_store",
          "path" => path,
          "status" => "available"
        }
      ]
    }

    assert {:ok, blob} = RedisStore.register_blob_ref(ref)
    assert [%{"storage" => "shared_fs", "path" => ^path} = location] = blob["locations"]
    refute Map.has_key?(location, "url")

    assert {:ok, fetched} = RedisStore.fetch_blob_ref(sha256)
    assert [%{"storage" => "shared_fs", "path" => ^path}] = fetched["locations"]
  end

  test "recovery evals can be listed by active status" do
    pending_id = "pending-eval-#{System.unique_integer([:positive])}"
    complete_id = "complete-eval-#{System.unique_integer([:positive])}"

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(pending_id, %{
               "status" => "pending",
               "created_at" => "2026-01-01T00:00:00Z"
             })

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(complete_id, %{
               "status" => "complete",
               "created_at" => "2026-01-02T00:00:00Z"
             })

    assert {:ok, pending_evals} = RedisStore.list_recovery_evals(["pending", "blocked"])
    assert Enum.map(pending_evals, & &1["eval_id"]) == [pending_id]

    assert {:ok, complete_evals} = RedisStore.list_recovery_evals(["complete"])
    assert Enum.map(complete_evals, & &1["eval_id"]) == [complete_id]

    assert {:ok, _eval} =
             RedisStore.update_recovery_eval(pending_id, %{
               "status" => "complete",
               "completed_at" => "2026-01-03T00:00:00Z"
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

  test "legacy recovery evals with embedded jobs can still be fetched", %{namespace: namespace} do
    eval_id = "legacy-job-eval-#{System.unique_integer([:positive])}"

    legacy_eval = %{
      "eval_id" => eval_id,
      "job_id" => "legacy-job",
      "status" => "complete",
      "job" => %{"job_id" => "legacy-job", "manifest" => %{"graph_id" => "legacy"}}
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["recovery", "eval", eval_id]),
               Jason.encode!(legacy_eval)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals"]),
               eval_id
             ])

    assert {:ok, fetched} = RedisStore.fetch_recovery_eval(eval_id)
    assert fetched["job"]["manifest"]["graph_id"] == "legacy"
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

  test "repair_recovery_indexes makes orphaned checkpoints discoverable and removes stale index entries",
       %{namespace: namespace} do
    job_id = "repair-job-#{System.unique_integer([:positive])}"
    agent_id = "worker"
    stale_job_id = "stale-job-#{System.unique_integer([:positive])}"
    stale_agent_id = "missing-worker"

    job = %{
      "job_id" => job_id,
      "status" => "running",
      "graph_id" => "repair_index_test",
      "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    agent = %{
      "agent_id" => agent_id,
      "node_id" => agent_id,
      "agent_type" => "executor",
      "current_state" => %{},
      "metadata" => %{}
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id]),
               Jason.encode!(job)
             ])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id, "agent", agent_id]),
               Jason.encode!(agent)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               stale_job_id
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["job", job_id, "agents"]),
               stale_agent_id
             ])

    assert {:ok, jobs_before} = RedisStore.list_jobs()
    refute Enum.any?(jobs_before, &(&1["job_id"] == job_id))

    assert {:ok, agents_before} = RedisStore.list_agents(job_id)
    refute Enum.any?(agents_before, &(&1["agent_id"] == agent_id))

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.repaired_jobs == 1
    assert result.repaired_agents == 1
    assert result.removed_stale_jobs == 1
    assert result.removed_stale_agents == 1

    assert {:ok, jobs_after} = RedisStore.list_jobs()
    assert Enum.any?(jobs_after, &(&1["job_id"] == job_id))

    assert {:ok, agents_after} = RedisStore.list_agents(job_id)
    assert Enum.any?(agents_after, &(&1["agent_id"] == agent_id))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["jobs"]),
               stale_job_id
             ])

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["job", job_id, "agents"]),
               stale_agent_id
             ])

    RedisStore.delete_job(job_id)
  end

  test "repair_recovery_indexes removes corrupt indexed checkpoints", %{namespace: namespace} do
    corrupt_job_id = "corrupt-job-#{System.unique_integer([:positive])}"
    job_id = "valid-job-#{System.unique_integer([:positive])}"
    corrupt_agent_id = "corrupt-worker"

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

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id, "agent", corrupt_agent_id]),
               "{not-json"
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["job", job_id, "agents"]),
               corrupt_agent_id
             ])

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.removed_stale_jobs == 1
    assert result.removed_stale_agents == 1

    assert {:ok, jobs} = RedisStore.list_jobs()
    refute Enum.any?(jobs, &(&1["job_id"] == corrupt_job_id))
    assert Enum.any?(jobs, &(&1["job_id"] == job_id))

    assert {:ok, agents} = RedisStore.list_agents(job_id)
    refute Enum.any?(agents, &(&1["agent_id"] == corrupt_agent_id))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["jobs"]),
               corrupt_job_id
             ])

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["job", job_id, "agents"]),
               corrupt_agent_id
             ])
  end

  test "list_job_summaries returns compact records and backfills legacy jobs", %{
    namespace: namespace
  } do
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

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["job", job_id, "summary"])
             ])

    assert {:ok, [backfilled]} = RedisStore.list_job_summaries()
    assert backfilled["job_id"] == job_id

    assert {:ok, encoded_summary} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["job", job_id, "summary"])
             ])

    assert is_binary(encoded_summary)
    assert byte_size(encoded_summary) < 2_000

    RedisStore.delete_job(job_id)
  end

  test "fenced leases reject stale job and agent writes" do
    job_id = "fenced-job-#{System.unique_integer([:positive])}"
    lease_name = "job:#{job_id}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "node-a", 5_000)
    assert lease["epoch"] >= 1

    assert {:error, {:locked, locked}} =
             RedisStore.acquire_fenced_lease(lease_name, "node-b", 5_000)

    assert locked["owner_id"] == "node-a"
    assert locked["epoch"] == lease["epoch"]

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => lease["epoch"]
             })

    assert {:error, {:stale_lease_epoch, stale_epoch, existing_epoch}} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => lease["epoch"] - 1
             })

    assert stale_epoch == lease["epoch"] - 1
    assert existing_epoch == lease["epoch"]

    assert {:error, {:stale_lease_epoch, stale_agent_epoch, existing_agent_epoch}} =
             RedisStore.persist_agent(job_id, "agent-a", %{
               "agent_id" => "agent-a",
               "status" => "running",
               "metadata" => %{"lease_epoch" => lease["epoch"] - 1}
             })

    assert stale_agent_epoch == lease["epoch"] - 1
    assert existing_agent_epoch == lease["epoch"]

    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-a", lease["epoch"])
    assert {:ok, next_lease} = RedisStore.acquire_fenced_lease(lease_name, "node-b", 5_000)
    assert next_lease["epoch"] > lease["epoch"]
    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-b", next_lease["epoch"])
  end

  test "fenced lease renewal and release enforce ownership" do
    lease_name = "lease-test-#{System.unique_integer([:positive])}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "node-a", 1_000)
    assert :ok = RedisStore.renew_fenced_lease(lease_name, "node-a", lease["epoch"], 1_000)

    assert {:error, :not_owner} =
             RedisStore.renew_fenced_lease(lease_name, "node-b", lease["epoch"], 1_000)

    assert {:error, :not_owner} =
             RedisStore.release_fenced_lease(lease_name, "node-b", lease["epoch"])

    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-a", lease["epoch"])
  end

  test "durable write acknowledgement reports timeout when not enough replicas are available" do
    required_replicas = 99
    Application.put_env(:mirror_neuron, :redis_wait_replicas, required_replicas)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 1)
    job_id = "wait-timeout-#{System.unique_integer([:positive])}"

    assert {:error, {:redis_replication_wait_timeout, acknowledgements, ^required_replicas}} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running"
             })

    assert is_integer(acknowledgements)
    assert acknowledgements < required_replicas
  end

  test "bundle archive and node state round-trip nested data" do
    fingerprint = "bundle-#{System.unique_integer([:positive])}"

    assert {:ok, archive} =
             RedisStore.persist_bundle_archive(fingerprint, %{
               "graph_id" => "graph",
               "files" => [%{"path" => "payload/main.py", "data" => "print(1)"}]
             })

    assert archive["fingerprint"] == fingerprint
    assert {:ok, fetched} = RedisStore.fetch_bundle_archive(fingerprint)
    assert get_in(fetched, ["files", Access.at(0), "path"]) == "payload/main.py"

    assert {:ok, state} =
             RedisStore.persist_node_state("node-a@test", %{
               status: :healthy,
               capacities: %{default: 2},
               flags: [:runtime]
             })

    assert state["status"] == :healthy
    assert state["capacities"]["default"] == 2
    assert state["flags"] == [:runtime]

    assert {:ok, fetched_state} = RedisStore.fetch_node_state("node-a@test")
    assert fetched_state["status"] == "healthy"
    assert fetched_state["flags"] == ["runtime"]

    assert {:ok, states} = RedisStore.list_node_states()
    assert Enum.any?(states, &(&1["node"] == "node-a@test"))
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

  test "bundle archive store reuses an existing fingerprint archive" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_archive_cache_#{System.unique_integer([:positive])}"
      )

    cache_dir = Path.join(tmp_dir, "cache")
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_BUNDLE_CACHE_DIR", cache_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
    end)

    bundle_dir = create_bundle(tmp_dir, "cached_archive")
    assert {:ok, fingerprint} = Fingerprint.compute(bundle_dir)

    assert {:ok, _archive} =
             RedisStore.persist_bundle_archive(fingerprint, %{
               "graph_id" => "cached_archive",
               "total_bytes" => 123,
               "files" => archive_files(bundle_dir)
             })

    assert {:ok, bundle} = JobBundle.load(bundle_dir)
    assert {:ok, result} = Archive.store(bundle)

    assert result.storage == "redis"
    assert result.total_bytes == 123
    assert File.exists?(Path.join([cache_dir, fingerprint, "manifest.json"]))
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp redis_key(namespace, parts), do: Enum.join([namespace | parts], ":")

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end

  defp create_bundle(base_dir, graph_id) do
    bundle_dir = Path.join(base_dir, graph_id)
    payloads_dir = Path.join(bundle_dir, "payloads")

    File.mkdir_p!(payloads_dir)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "flow" => %{
        "nodes" => [%{"node_id" => "node1", "agent_type" => "router", "role" => "root"}],
        "edges" => []
      }
    }

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(payloads_dir, "dummy.txt"), "hello")

    bundle_dir
  end

  defp archive_files(bundle_dir) do
    bundle_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      {:ok, contents} = File.read(path)

      %{
        "path" => Path.relative_to(path, bundle_dir),
        "bytes" => byte_size(contents),
        "data" => Base.encode64(contents)
      }
    end)
  end
end
