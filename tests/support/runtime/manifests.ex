defmodule MirrorNeuron.RuntimeFixtures.Manifests do
  alias MirrorNeuron.RuntimeTest.LongSleepRunner

  def profile_config(image) do
    %{
      "image" => image,
      "pool" => "default",
      "pool_slots" => 1,
      "required_capabilities" => ["video-codec:h264"],
      "reuse_shared_sandbox" => true,
      "persistent_workspace" => true
    }
  end

  def profiled_executor_manifest(graph_id, profile) do
    %{
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "entrypoints" => ["video_guardian"],
      "nodes" => [
        %{
          "node_id" => "video_guardian",
          "agent_type" => "executor",
          "role" => "root",
          "config" => %{
            "execution_profile" => profile,
            "runner_module" => "MirrorNeuron.RuntimeTest.ProfiledCompleteRunner",
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "initial_inputs" => %{"video_guardian" => [%{"stream" => "sample"}]},
      "policies" => %{"recovery_mode" => "local_restart"}
    }
  end

  def pause_resume_dag_manifest(graph_id) do
    %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "job_name" => graph_id,
      "contract" => %{"inputs" => [], "outputs" => [%{"id" => "review_packet"}]},
      "flow" => %{
        "steps" => [
          workflow_test_step("intake_documents", "Intake Documents", [], ["documents"]),
          workflow_test_step("manual_review", "Manual Review", ["documents"], ["approved_packet"]),
          workflow_test_step("write_packet", "Write Packet", ["approved_packet"], [
            "review_packet"
          ])
          |> Map.put("join", %{"mode" => "all_required"})
        ],
        "graph" => %{
          "schema" => "mn.workflow.problem_graph/v1",
          "mode" => "static_dag",
          "source" => "intake_documents",
          "sink" => "write_packet",
          "execution" => %{"strategy" => "parallel", "join_default" => "all_required"},
          "dynamic" => %{
            "enabled" => false,
            "patch_events" => [],
            "apply_at" => "between_steps"
          },
          "edges" => [
            %{
              "id" => "edge-intake-review",
              "from" => "intake_documents",
              "to" => "manual_review",
              "required" => true,
              "accepts" => ["done"]
            },
            %{
              "id" => "edge-review-write",
              "from" => "manual_review",
              "to" => "write_packet",
              "required" => true,
              "accepts" => ["done"]
            }
          ]
        }
      },
      "runtime" => %{
        "bindings" => %{
          "manual_review" => %{
            "type" => "team",
            "strategy" => "sequential",
            "workers" => [
              %{
                "id" => "router_worker",
                "node" => "root",
                "role" => "router",
                "required" => true
              },
              %{
                "id" => "sink_worker",
                "node" => "sink",
                "role" => "aggregator",
                "required" => true
              }
            ]
          }
        }
      },
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "manual_result"}
        },
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }
  end

  def workflow_test_step(id, title, requires, provides) do
    %{
      "id" => id,
      "title" => title,
      "requires" => requires,
      "provides" => provides,
      "control" => %{
        "required" => true,
        "timeout_seconds" => 300,
        "retry" => %{"max_attempts" => 2, "backoff" => "fixed", "delay_seconds" => 0},
        "failure_policy" => "fail_workflow",
        "uncertainty" => %{"policy" => "continue", "threshold" => 0.0}
      }
    }
  end

  def deployment_service_manifest(deployment_key, version) do
    %{
      "manifest_version" => "1.0",
      "type" => "service",
      "graph_id" => "deployment-runtime-test",
      "job_name" => deployment_key,
      "deployment" => %{"key" => deployment_key},
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"start" => true}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => LongSleepRunner,
            "output_message_type" => nil,
            "deployment_test_version" => version
          },
          "services" => [
            %{
              "name" => "deploy-runtime-api",
              "address" => "127.0.0.1",
              "port" => 19_090,
              "tags" => [version]
            }
          ]
        }
      ],
      "edges" => [],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "update" => %{
          "max_parallel" => 1,
          "min_healthy_ms" => 0,
          "healthy_deadline_ms" => 1_000
        }
      }
    }
  end

  def flow_manifest(%{} = manifest) do
    manifest = Map.put_new(manifest, "apiVersion", "mn.workflow/v1")
    manifest = Map.put_new(manifest, "kind", "Workflow")
    {nodes, manifest} = Map.pop(manifest, "nodes")
    {edges, manifest} = Map.pop(manifest, "edges")

    flow =
      manifest
      |> Map.get("flow", %{})
      |> maybe_put_topology("nodes", nodes)
      |> maybe_put_topology("edges", edges)

    Map.put(manifest, "flow", flow)
  end

  def flow_manifest(input), do: input

  def maybe_put_topology(flow, _key, nil), do: flow
  def maybe_put_topology(flow, key, value), do: Map.put(flow, key, value)
end
