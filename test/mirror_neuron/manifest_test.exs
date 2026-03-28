defmodule MirrorNeuron.ManifestTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest

  test "validates a well-formed manifest" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => ["router"],
      "nodes" => [
        %{
          "node_id" => "router",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "research_request"}
        },
        %{"node_id" => "sink", "agent_type" => "aggregator"}
      ],
      "edges" => [
        %{"from_node" => "router", "to_node" => "sink", "message_type" => "research_request"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(manifest)
    assert normalized.graph_id == "simple"
    assert normalized.entrypoints == ["router"]
  end

  test "rejects duplicate nodes and missing edge references" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "invalid",
      "entrypoints" => ["router"],
      "nodes" => [
        %{"node_id" => "router", "agent_type" => "router", "role" => "root_coordinator"},
        %{"node_id" => "router", "agent_type" => "aggregator"}
      ],
      "edges" => [
        %{"from_node" => "router", "to_node" => "missing", "message_type" => "research_request"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "duplicate node_id router"))
    assert Enum.any?(errors, &String.contains?(&1, "missing to_node missing"))
  end

  test "loads a job bundle from a folder with manifest.json and payloads" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_bundle_test_#{System.unique_integer([:positive])}"
      )

    payloads_dir = Path.join(tmp_dir, "payloads")

    File.mkdir_p!(payloads_dir)

    File.write!(
      Path.join(tmp_dir, "manifest.json"),
      Jason.encode!(%{
        "manifest_version" => "1.0",
        "graph_id" => "bundle-test",
        "entrypoints" => ["router"],
        "nodes" => [
          %{
            "node_id" => "router",
            "agent_type" => "router",
            "role" => "root_coordinator",
            "config" => %{"emit_type" => "research_request"}
          },
          %{"node_id" => "sink", "agent_type" => "aggregator"}
        ],
        "edges" => [
          %{"from_node" => "router", "to_node" => "sink", "message_type" => "research_request"}
        ],
        "policies" => %{"recovery_mode" => "local_restart"}
      })
    )

    assert {:ok, bundle} = JobBundle.load(tmp_dir)
    assert bundle.root_path == Path.expand(tmp_dir)
    assert bundle.payloads_path == Path.join(Path.expand(tmp_dir), "payloads")
    assert bundle.manifest.graph_id == "bundle-test"

    File.rm_rf!(tmp_dir)
  end
end
