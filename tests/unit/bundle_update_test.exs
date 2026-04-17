defmodule MirrorNeuron.BundleUpdateTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Bundle.{Fingerprint, Manager, Scanner}

  setup do
    Application.ensure_all_started(:mirror_neuron)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_bundle_update_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Clean up environment variables before each test
    System.delete_env("MIRROR_NEURON_BUNDLE_RELOAD_MODE")
    System.delete_env("MIRROR_NEURON_BUNDLE_RELOAD_INTERVAL_SECONDS")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      System.delete_env("MIRROR_NEURON_BUNDLE_RELOAD_MODE")
      System.delete_env("MIRROR_NEURON_BUNDLE_RELOAD_INTERVAL_SECONDS")
    end)

    %{dir: tmp_dir}
  end

  defp create_bundle(base_dir, graph_id, reload_mode \\ "manual", interval \\ 1) do
    bundle_dir = Path.join(base_dir, graph_id)
    payloads_dir = Path.join(bundle_dir, "payloads")

    File.mkdir_p!(payloads_dir)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "reload" => %{"mode" => reload_mode, "interval_seconds" => interval},
      "nodes" => [%{"node_id" => "node1", "agent_type" => "router", "role" => "root"}],
      "edges" => []
    }

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(payloads_dir, "dummy.txt"), "hello")

    bundle_dir
  end

  test "Manager respects MIRROR_NEURON_BUNDLE_RELOAD_MODE and MIRROR_NEURON_BUNDLE_RELOAD_INTERVAL_SECONDS environment variables",
       %{dir: dir} do
    System.put_env("MIRROR_NEURON_BUNDLE_RELOAD_MODE", "interval")
    System.put_env("MIRROR_NEURON_BUNDLE_RELOAD_INTERVAL_SECONDS", "5")

    # Create a bundle that is defined as manual in its manifest
    create_bundle(dir, "env_test_bundle", "manual", 60)

    Manager.register_dir(dir)
    Process.sleep(50)

    assert {:ok, record} = Manager.get_bundle("env_test_bundle")

    # The environment variables should have overridden the manifest
    assert record.bundle_struct.manifest.reload.mode == "interval"
    assert record.bundle_struct.manifest.reload.interval_seconds == 5
  end

  test "Bundle update actually modifies the loaded manifest when a file is changed", %{dir: dir} do
    bundle_dir = create_bundle(dir, "update_test_bundle", "manual")
    Manager.register_dir(dir)
    Process.sleep(50)

    assert {:ok, initial_record} = Manager.get_bundle("update_test_bundle")

    assert initial_record.bundle_struct.manifest.nodes == [
             %{
               node_id: "node1",
               agent_type: "router",
               role: "root",
               type: "generic",
               config: %{},
               checkpoint_policy: %{},
               retry_policy: %{},
               spawn_policy: %{},
               tool_bindings: []
             }
           ]

    # Update the manifest file
    new_manifest = %{
      "manifest_version" => "1.0",
      # Must match
      "graph_id" => "update_test_bundle",
      "reload" => %{"mode" => "manual", "interval_seconds" => 1},
      "nodes" => [
        %{"node_id" => "node1", "agent_type" => "router", "role" => "root"},
        # ADDED A NEW NODE
        %{"node_id" => "node2", "agent_type" => "executor"}
      ],
      "edges" => []
    }

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(new_manifest))

    # Trigger reload
    assert {:ok, resp} = Manager.reload("update_test_bundle", "manual_test")
    assert resp.changed == true
    assert resp.reloaded == true

    # Verify the updated bundle has the new node
    assert {:ok, final_record} = Manager.get_bundle("update_test_bundle")

    # The normalized nodes should now have 2 items
    nodes = final_record.bundle_struct.manifest.nodes
    assert length(nodes) == 2
    assert Enum.any?(nodes, &(&1.node_id == "node2" and &1.agent_type == "executor"))
  end
end
