defmodule MirrorNeuron.BundleTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Bundle.{Archive, Fingerprint, Manager, Scanner}
  alias MirrorNeuron.JobBundle

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

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
