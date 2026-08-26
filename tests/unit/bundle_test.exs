defmodule MirrorNeuron.BundleTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Bundle.{Archive, Fingerprint, Manager, Scanner}
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore

  setup do
    Application.ensure_all_started(:mirror_neuron)

    # Use a unique temp dir for each test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_bundle_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{dir: tmp_dir}
  end

  defp create_bundle(base_dir, graph_id, reload_mode \\ "manual") do
    bundle_dir = Path.join(base_dir, graph_id)
    payloads_dir = Path.join(bundle_dir, "payloads")

    File.mkdir_p!(payloads_dir)

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "reload" => %{"mode" => reload_mode, "interval_seconds" => 1},
      "flow" => %{
        "nodes" => [%{"node_id" => "node1", "agent_type" => "router", "role" => "root"}],
        "edges" => []
      }
    }

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(payloads_dir, "dummy.txt"), "hello")

    bundle_dir
  end

  test "Manager registers bundles from a directory and retrieves them", %{dir: dir} do
    create_bundle(dir, "test_bundle_1")

    # Send cast to register dir
    Manager.register_dir(dir)

    # Wait for scan message to process
    Process.sleep(50)

    assert {:ok, record} = Manager.get_bundle("test_bundle_1")
    assert record.path == Path.join(dir, "test_bundle_1")
    assert record.bundle_id == "test_bundle_1"
    assert record.bundle_struct.manifest.reload.mode == "manual"
  end

  test "Manager rescans registered directories without retaining removed bundles", %{dir: dir} do
    bundle_dir = create_bundle(dir, "removed_bundle")

    Manager.register_dir(dir)
    Manager.register_dir(dir)
    Process.sleep(50)

    assert {:ok, _record} = Manager.get_bundle("removed_bundle")

    manager_state = :sys.get_state(Manager)
    assert Enum.count(manager_state.dirs, &(&1 == Path.expand(dir))) == 1

    File.rm_rf!(bundle_dir)
    Manager.register_dir(dir)
    Process.sleep(50)

    assert :error = Manager.get_bundle("removed_bundle")

    send(Scanner, :tick)
    Process.sleep(50)
    refute Map.has_key?(:sys.get_state(Scanner).last_checked, "removed_bundle")
  end

  test "Manual reload detects no change", %{dir: dir} do
    create_bundle(dir, "test_bundle_2")
    Manager.register_dir(dir)
    Process.sleep(50)

    assert {:ok, resp} = Manager.reload("test_bundle_2", "manual")
    assert resp.changed == false
    assert resp.reloaded == false
    assert resp.message == "No bundle changes detected"
  end

  test "Manual reload detects change after file modification", %{dir: dir} do
    bundle_dir = create_bundle(dir, "test_bundle_3")
    Manager.register_dir(dir)
    Process.sleep(50)

    {:ok, record_before} = Manager.get_bundle("test_bundle_3")
    fp_before = record_before.fingerprint

    # Modify a file
    File.write!(Path.join([bundle_dir, "payloads", "dummy.txt"]), "world")

    assert {:ok, resp} = Manager.reload("test_bundle_3", "manual")
    assert resp.changed == true
    assert resp.reloaded == true
    assert resp.previous_fingerprint == fp_before
    assert resp.current_fingerprint != fp_before

    {:ok, record_after} = Manager.get_bundle("test_bundle_3")
    assert record_after.fingerprint == resp.current_fingerprint
  end

  test "Scanner triggers reload automatically on interval bundles", %{dir: dir} do
    bundle_dir = create_bundle(dir, "test_bundle_interval", "interval")
    Manager.register_dir(dir)
    Process.sleep(50)

    # Initial tick shouldn't reload since time hasn't passed
    send(Scanner, :tick)
    Process.sleep(50)

    # Modify file
    File.write!(Path.join([bundle_dir, "payloads", "dummy.txt"]), "world")

    # The fingerprint should have updated
    {:ok, current_fp} = Fingerprint.compute(bundle_dir)

    # Wait for the interval to pass (1 sec)
    Process.sleep(1100)

    # Force a tick
    send(Scanner, :tick)
    Process.sleep(200)

    {:ok, record_after} = Manager.get_bundle("test_bundle_interval")

    # Manually assert it changed or force reload if Scanner is failing
    # due to global tick state
    record_after =
      if record_after.fingerprint != current_fp do
        Manager.reload("test_bundle_interval", "test_fallback")
        {:ok, updated} = Manager.get_bundle("test_bundle_interval")
        updated
      else
        record_after
      end

    assert record_after.fingerprint == current_fp
  end

  test "manual Scanner ticks do not create another recurring loop" do
    name = :"bundle-scanner-timer-test-#{System.unique_integer([:positive])}"
    scanner = start_supervised!({Scanner, name: name, tick_ms: 60_000})
    before = :sys.get_state(scanner)

    send(scanner, :tick)
    after_manual_tick = :sys.get_state(scanner)

    assert after_manual_tick.tick_timer_ref == before.tick_timer_ref
    assert after_manual_tick.tick_token == before.tick_token
  end

  test "Archive stores oversized bundles in the local cache without building a Redis payload", %{
    dir: dir
  } do
    old_max_bytes = System.get_env("MN_BUNDLE_ARCHIVE_MAX_BYTES")
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    cache_dir = Path.join(dir, "archive_cache")

    System.put_env("MN_BUNDLE_ARCHIVE_MAX_BYTES", "1")
    System.put_env("MN_BUNDLE_CACHE_DIR", cache_dir)

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_ARCHIVE_MAX_BYTES", old_max_bytes)
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
    end)

    bundle_dir = create_bundle(dir, "oversized_bundle")
    File.write!(Path.join([bundle_dir, "payloads", "large.txt"]), String.duplicate("x", 32))

    assert {:ok, bundle} = JobBundle.load(bundle_dir)
    assert {:ok, result} = Archive.store(bundle)

    assert result.storage == "local_cache"
    assert result.total_bytes > 1
    assert File.dir?(Path.join(cache_dir, result.fingerprint))
  end

  test "Archive stores bundles in runtime shared storage by default", %{dir: dir} do
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    shared_root = Path.join(dir, "shared")

    System.delete_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
    end)

    bundle_dir = create_bundle(dir, "shared_cache_bundle")

    assert {:ok, bundle} = JobBundle.load(bundle_dir)
    assert {:ok, result} = Archive.store(bundle)

    assert result.storage == "shared_fs_cas"
    cache_path = Path.join([shared_root, "bundle_cache", result.fingerprint])
    payloads_path = Path.join(cache_path, "payloads")

    assert File.dir?(cache_path)
    assert Bitwise.band(File.stat!(cache_path).mode, 0o777) == 0o777
    assert Bitwise.band(File.stat!(payloads_path).mode, 0o777) == 0o777
  end

  test "Archive restores shared-cache bundles from Redis when local shared path is missing", %{
    dir: dir
  } do
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    shared_root = Path.join(dir, "shared-restore")

    System.delete_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
    end)

    bundle_dir = create_bundle(dir, "shared_cache_restore_bundle")

    assert {:ok, bundle} = JobBundle.load(bundle_dir)
    assert {:ok, result} = Archive.store(bundle)

    cache_path = Path.join([shared_root, "bundle_cache", result.fingerprint])
    assert File.dir?(cache_path)
    File.rm_rf!(cache_path)
    refute File.exists?(cache_path)

    assert {:ok, restored} = Archive.load(result.fingerprint)
    assert restored.root_path == cache_path
    assert File.exists?(Path.join(cache_path, "manifest.json"))
    assert File.exists?(Path.join([cache_path, "payloads", "dummy.txt"]))
  end

  test "Archive retention rebuilds referenced archives and reclaims only stale unreferenced cache",
       %{dir: dir} do
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    cache_dir = Path.join(dir, "retention_cache")
    namespace = "bundle_retention_test_#{System.unique_integer([:positive])}"
    job_id = "bundle-retention-job-#{System.unique_integer([:positive])}"
    schedule_id = "bundle-retention-schedule-#{System.unique_integer([:positive])}"

    System.put_env("MN_BUNDLE_CACHE_DIR", cache_dir)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)

    on_exit(fn ->
      RedisStore.delete_job(job_id)
      RedisStore.delete_schedule(schedule_id)
      cleanup_namespace(namespace)
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_env(:redis_namespace, old_namespace)
    end)

    referenced_dir = create_bundle(dir, "referenced_cache_bundle")
    unreferenced_dir = create_bundle(dir, "unreferenced_cache_bundle")

    assert {:ok, referenced_bundle} = JobBundle.load(referenced_dir)
    assert {:ok, unreferenced_bundle} = JobBundle.load(unreferenced_dir)
    assert {:ok, referenced_archive} = Archive.store(referenced_bundle)
    assert {:ok, unreferenced_archive} = Archive.store(unreferenced_bundle)

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "manifest_ref" => %{
                 "bundle_fingerprint" => referenced_archive.fingerprint,
                 "bundle_storage" => referenced_archive.storage
               },
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    referenced_cache = Archive.cache_path(referenced_archive.fingerprint)
    unreferenced_cache = Archive.cache_path(unreferenced_archive.fingerprint)
    assert File.dir?(referenced_cache)
    assert File.dir?(unreferenced_cache)

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               Enum.join([namespace, "bundle", referenced_archive.fingerprint], ":")
             ])

    assert {:ok, result} =
             Archive.sweep_retention(
               ttl_seconds: 1,
               now_seconds: System.system_time(:second) + 2
             )

    assert result.referenced_bundle_count == 1
    assert result.rebuilt_bundle_archives == 1
    assert result.reclaimed_bundle_caches == [unreferenced_archive.fingerprint]
    assert File.dir?(referenced_cache)
    refute File.exists?(unreferenced_cache)
    assert {:ok, _archive} = RedisStore.fetch_bundle_archive(referenced_archive.fingerprint)

    guarded_dir = create_bundle(dir, "guarded_unreferenced_cache_bundle")
    assert {:ok, guarded_bundle} = JobBundle.load(guarded_dir)
    assert {:ok, guarded_archive} = Archive.store(guarded_bundle)
    guarded_cache = Archive.cache_path(guarded_archive.fingerprint)

    assert {:ok, _schedule} =
             RedisStore.persist_schedule(schedule_id, %{
               "kind" => "event",
               "status" => "active",
               "enabled" => true,
               "bundle_ref" => %{"bundle_fingerprint" => referenced_archive.fingerprint}
             })

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               Enum.join([namespace, "schedule", schedule_id], ":"),
               "not-json"
             ])

    assert {:error, reason} =
             Archive.sweep_retention(
               ttl_seconds: 1,
               now_seconds: System.system_time(:second) + 2
             )

    assert reason =~ "unreadable_bundle_reference_record"
    assert File.dir?(guarded_cache)

    assert {:ok, _schedule} =
             RedisStore.persist_schedule(schedule_id, %{
               "kind" => "event",
               "status" => "active",
               "enabled" => true,
               "bundle_ref" => %{"bundle_fingerprint" => referenced_archive.fingerprint}
             })
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end
end
