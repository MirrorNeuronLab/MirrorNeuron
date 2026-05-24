defmodule MirrorNeuron.ManifestTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest

  test "fails when loading nonexistent file path (tries to parse as json)" do
    assert {:error, "unexpected byte" <> _} = Manifest.load("/path/does/not/exist.json")
  end

  test "fails when loading invalid json string directly" do
    assert {:error, "unexpected byte" <> _} = Manifest.load("invalid json string {")
  end

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

    assert {:error, errors} = Manifest.load(manifest)
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

    assert {:error, errors} = Manifest.load(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "missing from_node"))
    assert Enum.any?(errors, &String.contains?(&1, "missing to_node"))
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

    assert {:ok, norm} = Manifest.load(manifest)
    assert norm.entrypoints == ["router"]

    # Missing entirely uses root role node
    manifest_no_entry = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "nodes" => [%{"node_id" => "root", "agent_type" => "router", "role" => "root"}],
      "edges" => []
    }

    assert {:ok, norm2} = Manifest.load(manifest_no_entry)
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

    assert {:ok, norm} = Manifest.load(manifest)
    # The default entrypoint is router, list inputs map to first entrypoint
    assert norm.initial_inputs == %{"__entrypoints__" => [%{"payload" => 1}, %{"payload" => 2}]}
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

    assert {:error, errors} = Manifest.load(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "unsupported agent_type nil"))
  end

  test "validates a well-formed manifest" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "requiredContextEngine" => true,
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
    assert normalized.daemon == false
    assert normalized.required_context_engine == true
    assert normalized.entrypoints == ["router"]
    assert Enum.find(normalized.nodes, &(&1.node_id == "router")).type == "generic"
  end

  test "accepts auto recovery mode for adaptive runtime reliability" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "auto-recovery-mode",
      "entrypoints" => ["router"],
      "nodes" => [%{"node_id" => "router", "agent_type" => "router", "role" => "root"}],
      "edges" => [],
      "policies" => %{"recovery_mode" => "auto"}
    }

    assert {:ok, normalized} = Manifest.load(manifest)
    assert normalized.policies["recovery_mode"] == "auto"
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

    assert {:ok, normalized} = Manifest.load(manifest)
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

    assert {:error, errors} = Manifest.load(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "unsupported routing_mode"))
    assert Enum.any?(errors, &String.contains?(&1, "invalid conditions"))
  end

  test "serializes normalized manifests for durable local recovery reload" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "durable-reload",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "safe_to_retry" => true,
            "idempotency_key" => "job:worker:input"
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"},
      "initial_inputs" => %{"worker" => [%{"id" => 1}]}
    }

    assert {:ok, normalized} = Manifest.load(manifest)
    durable = Manifest.to_map(normalized)

    assert {:ok, reloaded} = Manifest.load(durable)
    assert reloaded.graph_id == normalized.graph_id
    assert reloaded.entrypoints == ["worker"]
    assert reloaded.initial_inputs == %{"worker" => [%{"id" => 1}]}

    worker = Enum.find(reloaded.nodes, &(&1.node_id == "worker"))
    assert worker.config["safe_to_retry"] == true
    assert worker.config["idempotency_key"] == "job:worker:input"
  end

  test "serializes lifecycle policies at job and node level" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "policy-roundtrip",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root",
          "policies" => %{
            "restart" => %{"attempts" => 1, "delay_ms" => 50},
            "reschedule" => %{"attempts" => 0}
          }
        }
      ],
      "edges" => [],
      "policies" => %{
        "recovery_mode" => "cluster_recover",
        "restart" => %{
          "attempts" => 3,
          "interval_ms" => 600_000,
          "delay_ms" => 1_000,
          "delay_function" => "exponential",
          "max_delay_ms" => 30_000,
          "mode" => "fail"
        },
        "reschedule" => %{
          "attempts" => 1,
          "interval_ms" => 86_400_000,
          "delay_ms" => 5_000,
          "delay_function" => "constant",
          "max_delay_ms" => 5_000,
          "unlimited" => false
        }
      }
    }

    assert {:ok, normalized} = Manifest.load(manifest)
    durable = Manifest.to_map(normalized)

    assert durable["policies"]["restart"]["attempts"] == 3
    assert durable["nodes"] |> hd() |> get_in(["policies", "restart", "attempts"]) == 1
    assert {:ok, _reloaded} = Manifest.load(durable)
  end

  test "rejects invalid lifecycle policies" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bad-policy",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root",
          "policies" => %{"reschedule" => %{"unlimited" => "yes"}}
        }
      ],
      "edges" => [],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => -1,
          "mode" => "always",
          "delay_function" => "random"
        }
      }
    }

    assert {:error, errors} = Manifest.load(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "policies.restart.attempts"))
    assert Enum.any?(errors, &String.contains?(&1, "policies.restart.mode"))
    assert Enum.any?(errors, &String.contains?(&1, "policies.restart.delay_function"))
    assert Enum.any?(errors, &String.contains?(&1, "nodes.worker.policies.reschedule.unlimited"))
  end

  test "defaults requiredContextEngine to false" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "entrypoints" => ["sink"],
      "nodes" => [%{"node_id" => "sink", "agent_type" => "aggregator"}],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(manifest)
    assert normalized.required_context_engine == false
  end

  test "rejects non-boolean requiredContextEngine" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "simple",
      "requiredContextEngine" => "yes",
      "entrypoints" => ["sink"],
      "nodes" => [%{"node_id" => "sink", "agent_type" => "aggregator"}],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(manifest)
    assert "requiredContextEngine must be a boolean" in errors
  end

  test "accepts explicit daemon manifests" do
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

    assert {:ok, normalized} = Manifest.load(manifest)
    assert normalized.daemon == true
  end

  test "rejects non-boolean daemon values" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "invalid-long-lived",
      "daemon" => "yes",
      "entrypoints" => ["streamer"],
      "nodes" => [
        %{"node_id" => "streamer", "agent_type" => "module", "type" => "stream", "role" => "root"}
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:error, errors} = Manifest.load(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "daemon must be a boolean"))
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

    assert {:ok, normalized} = Manifest.load(manifest)
    assert Enum.find(normalized.nodes, &(&1.node_id == "source")).type == "stream"
    assert Enum.find(normalized.nodes, &(&1.node_id == "sink")).type == "reduce"
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

    assert {:error, errors} = Manifest.load(manifest)
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

    assert {:error, errors} = Manifest.load(manifest)
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
