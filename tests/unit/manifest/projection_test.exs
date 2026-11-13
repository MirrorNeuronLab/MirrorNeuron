defmodule MirrorNeuron.ManifestTest.ProjectionTest do
  use MirrorNeuron.ManifestCase, async: true

  alias MirrorNeuron.Manifest

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
end
