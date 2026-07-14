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

  test "round-trips workflow manifest fields and problem DAG metadata" do
    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "tax-dag",
      "job_name" => "Tax DAG",
      "contract" => %{
        "inputs" => %{"folder" => %{"type" => "string"}},
        "outputs" => %{"primary" => %{"path" => "final_artifact.json"}}
      },
      "flow" => %{
        "entrypoint" => "intake",
        "graph" => %{
          "schema" => "mn.workflow.problem_graph/v1",
          "mode" => "static_dag",
          "source" => "intake",
          "sink" => "write",
          "execution" => %{"strategy" => "parallel", "max_parallel_steps" => 2},
          "dynamic" => %{"enabled" => false},
          "edges" => [
            %{"id" => "intake-to-write", "from" => "intake", "to" => "write", "required" => true}
          ]
        },
        "steps" => [
          %{
            "id" => "intake",
            "run" => "intake",
            "control" => %{
              "required" => true,
              "timeout_seconds" => 30,
              "retry" => %{"max_attempts" => 2, "backoff_seconds" => 1},
              "failure_policy" => "fail_workflow",
              "uncertainty" => %{"min_confidence" => 0.8, "on_low_confidence" => "human_review"}
            }
          },
          %{"id" => "write", "run" => "write", "join" => %{"mode" => "all_required"}}
        ]
      },
      "runtime" => %{
        "bindings" => %{
          "intake" => %{"type" => "team", "workers" => [%{"id" => "worker", "kind" => "worker"}]},
          "write" => %{"type" => "single", "workers" => [%{"id" => "writer"}]}
        }
      },
      "term" => %{"privacy" => "local"},
      "entrypoints" => ["root"],
      "nodes" => [%{"node_id" => "root", "agent_type" => "router", "role" => "root"}],
      "edges" => []
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    durable = Manifest.to_map(normalized)

    assert durable["apiVersion"] == "mn.workflow/v1"
    assert durable["kind"] == "Workflow"
    assert durable["contract"]["outputs"]["primary"]["path"] == "final_artifact.json"
    assert durable["flow"]["graph"]["schema"] == "mn.workflow.problem_graph/v1"
    assert durable["flow"]["graph"]["execution"]["strategy"] == "parallel"
    assert durable["flow"]["steps"] |> hd() |> get_in(["control", "retry", "max_attempts"]) == 2
    assert durable["flow"]["steps"] |> List.last() |> get_in(["join", "mode"]) == "all_required"

    assert durable["runtime"]["bindings"]["intake"]["workers"] |> hd() |> Map.get("kind") ==
             "worker"

    assert durable["term"]["privacy"] == "local"
    assert {:ok, _reloaded} = Manifest.load(flow_manifest(durable))
  end

  test "topology remains runtime agent topology while flow graph remains problem DAG" do
    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "layered-runtime",
      "contract" => %{"inputs" => %{}, "outputs" => %{"primary" => %{"path" => "final.json"}}},
      "flow" => %{
        "entrypoint" => "intake",
        "graph" => %{
          "schema" => "mn.workflow.problem_graph/v1",
          "mode" => "static_dag",
          "source" => "intake",
          "sink" => "report",
          "edges" => [%{"id" => "intake-to-report", "from" => "intake", "to" => "report"}]
        },
        "steps" => [
          %{"id" => "intake", "run" => "intake"},
          %{"id" => "report", "run" => "report"}
        ]
      },
      "runtime" => %{
        "bindings" => %{
          "intake" => %{"workers" => [%{"id" => "intake_worker"}]},
          "report" => %{"workers" => [%{"id" => "writer"}]}
        }
      },
      "entrypoints" => ["router"],
      "nodes" => [
        %{"node_id" => "router", "agent_type" => "router", "role" => "root"},
        %{"node_id" => "executor", "agent_type" => "executor", "role" => "worker"}
      ],
      "edges" => [
        %{
          "edge_id" => "router-executor",
          "from_node" => "router",
          "to_node" => "executor",
          "message_type" => "work"
        }
      ]
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))

    topology = Manifest.topology(normalized)
    assert Enum.map(topology["nodes"], & &1["node_id"]) == ["router", "executor"]
    assert Enum.map(topology["edges"], & &1["edge_id"]) == ["router-executor"]
    refute Enum.any?(topology["nodes"], &(&1["node_id"] in ["intake", "report"]))
    refute Enum.any?(topology["edges"], &(&1["edge_id"] == "intake-to-report"))

    durable = Manifest.to_map(normalized)
    assert get_in(durable, ["flow", "graph", "edges", Access.at(0), "id"]) == "intake-to-report"

    assert get_in(durable, ["runtime", "bindings", "intake", "workers", Access.at(0), "id"]) ==
             "intake_worker"
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

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.graph_id == "simple"
    assert normalized.type == "batch"
    assert normalized.required_context_engine == true
    assert normalized.entrypoints == ["router"]
    assert Enum.find(normalized.nodes, &(&1.node_id == "router")).type == "generic"
  end

  test "accepts service declarations and required service checks" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "services",
      "entrypoints" => ["worker"],
      "required_services" => [
        %{
          "name" => "ollama",
          "origin" => "external",
          "checks" => [
            %{
              "name" => "health",
              "type" => "http",
              "url" => "${config.llm.api_base}/api/tags",
              "timeout_ms" => 1000
            }
          ]
        }
      ],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root",
          "services" => [%{"name" => "agent-api", "port" => 8080}],
          "requires_services" => [%{"name" => "ollama"}]
        }
      ],
      "edges" => []
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert [%{"name" => "ollama"}] = normalized.required_services
    assert [%{"name" => "agent-api", "port" => 8080}] = hd(normalized.nodes).services

    serialized = Manifest.to_map(normalized)

    refute Map.has_key?(serialized, "nodes")
    refute Map.has_key?(serialized, "edges")

    assert get_in(serialized, [
             "flow",
             "nodes",
             Access.at(0),
             "requires_services",
             Access.at(0),
             "name"
           ]) == "ollama"
  end

  test "rejects malformed service declarations" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bad-services",
      "entrypoints" => ["worker"],
      "required_services" => [
        %{"name" => "bad service", "checks" => [%{"type" => "smtp"}]}
      ],
      "nodes" => [%{"node_id" => "worker", "agent_type" => "executor", "role" => "root"}],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "required_services.0.name"))
    assert Enum.any?(errors, &String.contains?(&1, "checks.0.type"))
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

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
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

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    durable = Manifest.to_map(normalized)

    assert {:ok, reloaded} = Manifest.load(flow_manifest(durable))
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

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    durable = Manifest.to_map(normalized)

    assert durable["policies"]["restart"]["attempts"] == 3
    refute Map.has_key?(durable, "nodes")
    refute Map.has_key?(durable, "edges")
    assert durable["flow"]["nodes"] |> hd() |> get_in(["policies", "restart", "attempts"]) == 1
    assert {:ok, _reloaded} = Manifest.load(flow_manifest(durable))
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

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
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

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
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

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert "requiredContextEngine must be a boolean" in errors
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

  test "rejects legacy complete_job config keys" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "legacy-completion-config",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_job" => true}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported complete_job"))
  end

  test "rejects bare complete_on_message without output or terminal sink" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bare-complete-on-message",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "complete_on_message requires"))
  end

  test "rejects bare complete_after without output or terminal sink" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bare-complete-after",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_after" => 2}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "complete_after requires"))
  end

  test "rejects workflow step nodes that declare complete_run" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "workflow-step-complete-run",
      "entrypoints" => ["step_a"],
      "flow" => %{
        "steps" => [%{"id" => "step_a", "run" => "step_a"}],
        "graph" => %{"edges" => []}
      },
      "nodes" => [
        %{
          "node_id" => "step_a",
          "agent_type" => "executor",
          "config" => %{"complete_run" => true}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))

    assert Enum.any?(
             errors,
             &String.contains?(&1, "workflow step node step_a cannot declare complete_run")
           )
  end

  test "rejects terminal sinks with outgoing edges" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "terminal-sink-outgoing-edge",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        },
        %{"node_id" => "after_sink", "agent_type" => "aggregator"}
      ],
      "edges" => [
        %{"from_node" => "sink", "to_node" => "after_sink", "message_type" => "done"}
      ]
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))

    assert Enum.any?(
             errors,
             &String.contains?(&1, "terminal sink sink must not have outgoing edges")
           )
  end

  test "accepts event-driven DAG triggers and validates DAG trigger rules" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "event-driven-dag",
      "entrypoints" => ["sensor"],
      "triggers" => [
        %{
          "name" => "dataset-uploaded",
          "enabled" => true,
          "event_type" => "file_uploaded",
          "filters" => %{"path" => %{"prefix" => "/datasets/"}}
        }
      ],
      "flow" => %{
        "steps" => [
          %{"id" => "sensor", "run" => "sensor"},
          %{
            "id" => "publish",
            "run" => "publish",
            "trigger_rule" => %{"rule" => "quorum_success", "quorum" => 1}
          }
        ],
        "graph" => %{
          "edges" => [%{"id" => "sensor-publish", "from" => "sensor", "to" => "publish"}]
        }
      },
      "nodes" => [
        %{"node_id" => "sensor", "agent_type" => "sensor", "role" => "root"},
        %{"node_id" => "publish", "agent_type" => "executor"}
      ],
      "edges" => [
        %{"from_node" => "sensor", "to_node" => "publish", "message_type" => "file_ready"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.triggers |> hd() |> Map.fetch!("event_type") == "file_uploaded"

    assert {:error, errors} =
             Manifest.load(
               put_in(
                 flow_manifest(manifest),
                 ["flow", "steps", Access.at(1), "trigger_rule", "quorum"],
                 2
               )
             )

    assert Enum.any?(errors, &String.contains?(&1, "quorum 2 exceeds"))
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

  defp flow_manifest(manifest) do
    {nodes, manifest} = Map.pop(manifest, "nodes")
    {edges, manifest} = Map.pop(manifest, "edges")

    if is_list(nodes) or is_list(edges) do
      flow = Map.get(manifest, "flow", %{}) || %{}

      flow =
        flow
        |> maybe_put_topology("nodes", nodes)
        |> maybe_put_topology("edges", edges)

      Map.put(manifest, "flow", flow)
    else
      manifest
    end
  end

  defp maybe_put_topology(flow, _key, nil), do: flow
  defp maybe_put_topology(flow, key, value), do: Map.put(flow, key, value)
end
