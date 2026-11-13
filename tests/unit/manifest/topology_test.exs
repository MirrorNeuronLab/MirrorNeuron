defmodule MirrorNeuron.ManifestTest.TopologyTest do
  use MirrorNeuron.ManifestCase, async: true

  alias MirrorNeuron.Manifest

  test "fails when edge is missing message_type" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => ["router"],
      "nodes" => [
        %{"node_id" => "router", "agent_type" => "router", "role" => "root"}
      ],
      "edges" => [
        # missing message_type
        %{"from_node" => "router", "to_node" => "router"}
      ]
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "must define message_type"))
  end

  test "fails when edge is missing from_node or to_node" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => ["router"],
      "nodes" => [
        %{"node_id" => "router", "agent_type" => "router", "role" => "root"}
      ],
      "edges" => [
        %{"to_node" => "router", "message_type" => "msg"},
        %{"from_node" => "router", "message_type" => "msg"}
      ]
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "missing from_node"))
    assert Enum.any?(errors, &String.contains?(&1, "missing to_node"))
  end

  test "validates missing agent_type" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => ["router"],
      "nodes" => [
        # missing agent_type
        %{"node_id" => "router", "role" => "root"}
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported agent_type nil"))
  end

  test "normalizes and validates state-driven route conditions" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "conditional-routing",
      "entrypoints" => ["router"],
      "nodes" => [
        %{"node_id" => "router", "agent_type" => "router", "role" => "root"},
        %{"node_id" => "finance", "agent_type" => "aggregator"}
      ],
      "edges" => [
        %{
          "edge_id" => "finance-route",
          "from_node" => "router",
          "to_node" => "finance",
          "message_type" => "classified_request",
          "routing_mode" => "first_match",
          "conditions" => %{"expr" => "${payload.domain} == \"finance\""}
        }
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    edge = hd(normalized.edges)
    assert edge.routing_mode == "first_match"
    assert edge.conditions == %{"expr" => "${payload.domain} == \"finance\""}
    assert hd(Manifest.topology(normalized)["edges"])["conditions"] == edge.conditions
  end

  test "rejects unsupported routing modes and invalid route conditions" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "conditional-routing",
      "entrypoints" => ["router"],
      "nodes" => [
        %{"node_id" => "router", "agent_type" => "router", "role" => "root"},
        %{"node_id" => "finance", "agent_type" => "aggregator"}
      ],
      "edges" => [
        %{
          "edge_id" => "bad-route",
          "from_node" => "router",
          "to_node" => "finance",
          "message_type" => "classified_request",
          "routing_mode" => "random",
          "conditions" => %{"expr" => "System.halt()"}
        }
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported routing_mode"))
    assert Enum.any?(errors, &String.contains?(&1, "invalid conditions"))
  end

  test "accepts supported template types" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "streaming",
      "entrypoints" => ["source"],
      "nodes" => [
        %{
          "node_id" => "source",
          "agent_type" => "executor",
          "type" => "stream",
          "role" => "root"
        },
        %{"node_id" => "sink", "agent_type" => "aggregator", "type" => "reduce"}
      ],
      "edges" => [
        %{"from_node" => "source", "to_node" => "sink", "message_type" => "telemetry_chunk"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert Enum.find(normalized.nodes, &(&1.node_id == "source")).type == "stream"
    assert Enum.find(normalized.nodes, &(&1.node_id == "sink")).type == "reduce"
  end

  test "accepts step boundary agent template combinations" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "step-boundaries",
      "entrypoints" => ["analyze__start"],
      "nodes" => [
        %{
          "node_id" => "analyze__start",
          "agent_type" => "step_source",
          "type" => "generic"
        },
        %{
          "node_id" => "analyze__join",
          "agent_type" => "step_join",
          "type" => "reduce"
        },
        %{
          "node_id" => "analyze__end",
          "agent_type" => "step_sink",
          "type" => "reduce"
        }
      ],
      "edges" => [
        %{
          "from_node" => "analyze__start",
          "to_node" => "analyze__join",
          "message_type" => "analyze_started"
        },
        %{
          "from_node" => "analyze__join",
          "to_node" => "analyze__end",
          "message_type" => "analyze_joined"
        }
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert Enum.find(normalized.nodes, &(&1.node_id == "analyze__start")).type == "generic"
    assert Enum.find(normalized.nodes, &(&1.node_id == "analyze__join")).type == "reduce"
    assert Enum.find(normalized.nodes, &(&1.node_id == "analyze__end")).type == "reduce"
  end

  test "rejects unsupported template types" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "invalid-template",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "type" => "mystery",
          "role" => "root"
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported template type"))
  end

  test "rejects incompatible template and agent_type combinations" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "invalid-combo",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "aggregator",
          "type" => "stream",
          "role" => "root"
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "template type"))
    assert Enum.any?(errors, &String.contains?(&1, "agent_type"))
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

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "duplicate node_id router"))
    assert Enum.any?(errors, &String.contains?(&1, "missing to_node missing"))
  end
end
