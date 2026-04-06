defmodule MirrorNeuron.JobBundleTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest

  @valid_manifest_map %{
    "manifest_version" => "1.0",
    "graph_id" => "test_graph",
    "entrypoints" => ["test_node"],
    "nodes" => [
      %{
        "node_id" => "test_node",
        "agent_type" => "router"
      }
    ],
    "edges" => []
  }

  test "load/1 with JobBundle struct returns ok" do
    bundle = %JobBundle{manifest: %Manifest{graph_id: "test"}}
    assert {:ok, ^bundle} = JobBundle.load(bundle)
  end

  test "load/1 with Manifest struct wraps it in bundle" do
    manifest = %Manifest{graph_id: "test"}
    assert {:ok, %JobBundle{manifest: ^manifest}} = JobBundle.load(manifest)
  end

  test "load/1 with valid map loads manifest" do
    assert {:ok, bundle} = JobBundle.load(@valid_manifest_map)
    assert bundle.manifest.graph_id == "test_graph"
  end

  test "load/1 with string path to valid json string parses it" do
    json_str = Jason.encode!(@valid_manifest_map)
    assert {:ok, bundle} = JobBundle.load(json_str)
    assert bundle.manifest.graph_id == "test_graph"
  end

  test "load/1 with invalid json string returns error" do
    assert {:error, "unexpected byte" <> _} = JobBundle.load("invalid json string {")
  end

  test "load/1 with path to regular file instead of dir returns error" do
    # Create a dummy file
    path = "dummy_file.json"
    File.write!(path, "{}")
    on_exit(fn -> File.rm!(path) end)

    expanded = Path.expand(path)
    assert {:error, "expected a job folder, got file " <> ^expanded} = JobBundle.load(path)
  end

  test "load/1 with valid directory structure" do
    dir = "test_bundle_dir"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(@valid_manifest_map))
    File.mkdir_p!(Path.join(dir, "payloads"))

    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, bundle} = JobBundle.load(dir)
    assert bundle.root_path == Path.expand(dir)
    assert bundle.manifest_path == Path.join(Path.expand(dir), "manifest.json")
    assert bundle.payloads_path == Path.join(Path.expand(dir), "payloads")
    assert bundle.manifest.graph_id == "test_graph"
  end

  test "load/1 with directory missing manifest returns error" do
    dir = "test_bundle_dir_no_manifest"
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "payloads"))

    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, "job folder is missing manifest.json:" <> _} = JobBundle.load(dir)
  end

  test "load/1 with directory missing payloads returns error" do
    dir = "test_bundle_dir_no_payloads"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(@valid_manifest_map))

    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, "job folder is missing payloads/:" <> _} = JobBundle.load(dir)
  end
end
