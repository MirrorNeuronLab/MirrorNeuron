defmodule MirrorNeuron.ManifestTest.LoadingTest do
  use MirrorNeuron.ManifestCase, async: true

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest

  test "fails when loading nonexistent file path (tries to parse as json)" do
    assert {:error, "unexpected byte" <> _} = Manifest.load("/path/does/not/exist.json")
  end

  test "fails when loading invalid json string directly" do
    assert {:error, "unexpected byte" <> _} = Manifest.load("invalid json string {")
  end

  test "rejects retired and missing api versions" do
    assert {:error, retired_errors} =
             Manifest.load(%{"apiVersion" => "mn.workflow/unsupported", "graph_id" => "legacy"})

    assert Enum.any?(retired_errors, &String.contains?(&1, "apiVersion must be mn.workflow/v1"))

    assert {:error, missing_errors} = Manifest.load(%{"graph_id" => "missing-version"})

    assert Enum.any?(
             missing_errors,
             &String.contains?(&1, "apiVersion must be mn.workflow/v1")
           )
  end

  test "rejects legacy top-level nodes and edges" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "legacy-topology",
      "entrypoints" => ["router"],
      "nodes" => [%{"node_id" => "router", "agent_type" => "router", "role" => "root"}],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "top-level nodes"))
    assert Enum.any?(errors, &String.contains?(&1, "top-level edges"))
  end

  test "normalizes entrypoints correctly from map and string" do
    # From string
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => "router",
      "nodes" => [%{"node_id" => "router", "agent_type" => "router", "role" => "root"}],
      "edges" => []
    }

    assert {:ok, norm} = Manifest.load(flow_manifest(manifest))
    assert norm.entrypoints == ["router"]

    # Missing entirely uses root role node
    manifest_no_entry = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "nodes" => [%{"node_id" => "root", "agent_type" => "router", "role" => "root"}],
      "edges" => []
    }

    assert {:ok, norm2} = Manifest.load(flow_manifest(manifest_no_entry))
    assert norm2.entrypoints == ["root"]
  end

  test "normalizes initial_inputs from list" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => ["router"],
      "nodes" => [%{"node_id" => "router", "agent_type" => "router", "role" => "root"}],
      "edges" => [],
      "initial_inputs" => [%{"payload" => 1}, %{"payload" => 2}]
    }

    assert {:ok, norm} = Manifest.load(flow_manifest(manifest))
    # The default entrypoint is router, list inputs map to first entrypoint
    assert norm.initial_inputs == %{"__entrypoints__" => [%{"payload" => 1}, %{"payload" => 2}]}
  end

  test "validates a well-formed manifest" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "required_context_engine" => true,
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

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.graph_id == "simple"
    assert normalized.type == "batch"
    assert normalized.required_context_engine == true
    assert normalized.entrypoints == ["router"]
    assert Enum.find(normalized.nodes, &(&1.node_id == "router")).type == "generic"
  end

  test "defaults required_context_engine to false" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => ["sink"],
      "nodes" => [%{"node_id" => "sink", "agent_type" => "aggregator"}],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.required_context_engine == false
  end

  test "normalizes null policies to an empty policy object" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "null-policies",
      "entrypoints" => ["sink"],
      "nodes" => [%{"node_id" => "sink", "agent_type" => "aggregator"}],
      "edges" => [],
      "policies" => nil
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.policies == %{}
  end

  test "rejects map-valued graph and job identifiers" do
    base = %{
      "manifest_version" => "1.0",
      "entrypoints" => ["sink"],
      "nodes" => [%{"node_id" => "sink", "agent_type" => "aggregator"}],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, graph_errors} = Manifest.load(flow_manifest(Map.put(base, "graph_id", %{})))
    assert "graph_id must be a non-empty string" in graph_errors
    assert "job_name must be a non-empty string" in graph_errors

    assert {:error, job_name_errors} =
             Manifest.load(
               flow_manifest(
                 base
                 |> Map.put("graph_id", "valid-graph")
                 |> Map.put("job_name", %{})
               )
             )

    assert "job_name must be a non-empty string" in job_name_errors
  end

  test "rejects non-boolean required_context_engine" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "required_context_engine" => "yes",
      "entrypoints" => ["sink"],
      "nodes" => [%{"node_id" => "sink", "agent_type" => "aggregator"}],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert "required_context_engine must be a boolean" in errors
  end

  test "rejects legacy daemon manifests" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "long-lived",
      "daemon" => true,
      "entrypoints" => ["streamer"],
      "nodes" => [
        %{"node_id" => "streamer", "agent_type" => "module", "type" => "stream", "role" => "root"}
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "daemon is no longer supported"))
  end

  test "accepts explicit service type" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "service-type",
      "type" => "service",
      "entrypoints" => ["streamer"],
      "nodes" => [
        %{"node_id" => "streamer", "agent_type" => "module", "type" => "stream", "role" => "root"}
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.type == "service"
  end

  test "rejects unsupported service type values" do
    for unsupported_type <- ["daemon", "deamon"] do
      manifest = %{
        "manifest_version" => "1.0",
        "graph_id" => "invalid-long-lived",
        "type" => unsupported_type,
        "entrypoints" => ["streamer"],
        "nodes" => [
          %{
            "node_id" => "streamer",
            "agent_type" => "module",
            "type" => "stream",
            "role" => "root"
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      }

      assert {:error, errors} = Manifest.load(flow_manifest(manifest))
      assert Enum.any?(errors, &String.contains?(&1, "type must be service or omitted for batch"))
    end
  end

  test "loads a job bundle from a folder with manifest.json and payloads" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_bundle_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    payloads_dir = Path.join(tmp_dir, "payloads")

    File.mkdir_p!(payloads_dir)

    File.write!(
      Path.join(tmp_dir, "manifest.json"),
      flow_manifest(%{
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
      |> Jason.encode!()
    )

    assert {:ok, bundle} = JobBundle.load(tmp_dir)
    assert bundle.root_path == Path.expand(tmp_dir)
    assert bundle.payloads_path == Path.join(Path.expand(tmp_dir), "payloads")
    assert bundle.manifest.graph_id == "bundle-test"
  end
end
