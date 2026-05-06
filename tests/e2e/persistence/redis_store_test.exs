defmodule MirrorNeuron.Persistence.RedisStoreTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Bundle.{Archive, Fingerprint}
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.EventBus

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

  test "retention sweep deletes expired terminal jobs and stale job ids" do
    job_id = "terminal-retention-#{System.unique_integer([:positive])}"

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
    Application.put_env(:mirror_neuron, :redis_wait_replicas, 1)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 1)
    job_id = "wait-timeout-#{System.unique_integer([:positive])}"

    assert {:error, {:redis_replication_wait_timeout, acknowledgements, 1}} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running"
             })

    assert is_integer(acknowledgements)
    assert acknowledgements < 1
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
      "nodes" => [%{"node_id" => "node1", "agent_type" => "router", "role" => "root"}],
      "edges" => []
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
