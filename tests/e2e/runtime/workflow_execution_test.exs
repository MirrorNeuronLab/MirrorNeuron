defmodule MirrorNeuron.Runtime.WorkflowExecutionTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.DeliveryChannels
  alias MirrorNeuron.RuntimeTest.WorkflowFirstRunner
  alias MirrorNeuron.RuntimeTest.WorkflowSecondRunner
  alias MirrorNeuron.RuntimeTest.ContextRouterAgent

  test "runs a manifest to completion and persists job state" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "research_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{
        "ingress" => [%{"text" => "Summarize charging adoption"}]
      },
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "research_request"}
        },
        %{"node_id" => "router", "agent_type" => "router"},
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
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "router", "message_type" => "research_request"},
        %{"from_node" => "router", "to_node" => "sink", "message_type" => "research_request"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job_id =~ ~r/^rt-[a-f0-9]{8}$/
    assert job["status"] == "completed"

    assert {:ok, persisted_job} = MirrorNeuron.inspect_job(job_id)
    assert persisted_job["status"] == "completed"

    assert {:ok, agents} = MirrorNeuron.inspect_agents(job_id)
    assert Enum.any?(agents, &(&1["agent_id"] == "ingress"))
    assert Enum.any?(agents, &(&1["agent_id"] == "sink"))

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_completed"))

    wait_until(fn -> agent_unregistered?(job_id, "ingress") end, 2_000)
    wait_until(fn -> agent_unregistered?(job_id, "router") end, 2_000)
    wait_until(fn -> agent_unregistered?(job_id, "sink") end, 2_000)

    RedisStore.delete_job(job_id)
  end

  test "routes a multi-agent logical step through source, join, and sink boundaries" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "step_boundary_runtime",
      "entrypoints" => ["analyze__start"],
      "initial_inputs" => %{
        "analyze__start" => [%{"args" => [], "kwargs" => %{"request" => "Acme"}}]
      },
      "flow" => %{
        "steps" => [
          %{
            "id" => "analyze",
            "run" => "analyze__start",
            "agent_id" => "analyze__start",
            "agent_ids" => [
              "analyze__start",
              "analyze__research_a",
              "analyze__research_b",
              "analyze__join",
              "analyze__end"
            ],
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 5,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
            }
          }
        ],
        "graph" => %{"edges" => []}
      },
      "nodes" => [
        %{
          "node_id" => "analyze__start",
          "agent_type" => "step_source",
          "config" => %{
            "step_id" => "analyze",
            "required_upstreams" => [],
            "fields" => %{
              "request" => %{"$ref" => "run_input", "path" => ["request"]}
            },
            "output_message_type" => "analyze_started"
          }
        },
        %{
          "node_id" => "analyze__research_a",
          "agent_type" => "router",
          "config" => %{"emit_type" => "research_a_completed"}
        },
        %{
          "node_id" => "analyze__research_b",
          "agent_type" => "router",
          "config" => %{"emit_type" => "research_b_completed"}
        },
        %{
          "node_id" => "analyze__join",
          "agent_type" => "step_join",
          "config" => %{
            "expected_sources" => ["analyze__research_a", "analyze__research_b"],
            "output_keys" => %{
              "analyze__research_a" => "research_a",
              "analyze__research_b" => "research_b"
            },
            "output_message_type" => "research_joined"
          }
        },
        %{
          "node_id" => "analyze__end",
          "agent_type" => "step_sink",
          "config" => %{
            "step_id" => "analyze",
            "fields" => %{"result" => %{"$ref" => "flow_output"}},
            "output_message_type" => "analyze_completed"
          }
        },
        %{
          "node_id" => "workflow__terminal",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_after" => 1,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [
        %{
          "from_node" => "analyze__start",
          "to_node" => "analyze__research_a",
          "message_type" => "analyze_started"
        },
        %{
          "from_node" => "analyze__start",
          "to_node" => "analyze__research_b",
          "message_type" => "analyze_started"
        },
        %{
          "from_node" => "analyze__research_a",
          "to_node" => "analyze__join",
          "message_type" => "research_a_completed"
        },
        %{
          "from_node" => "analyze__research_b",
          "to_node" => "analyze__join",
          "message_type" => "research_b_completed"
        },
        %{
          "from_node" => "analyze__join",
          "to_node" => "analyze__end",
          "message_type" => "research_joined"
        },
        %{
          "from_node" => "analyze__end",
          "to_node" => "workflow__terminal",
          "message_type" => "analyze_completed"
        }
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["workflow_state", "steps", "analyze", "status"]) == "completed"
    assert get_in(job, ["result", "output", "last_message", "outputs", "result"])

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "step_source_dispatched"))
    assert Enum.any?(events, &(&1["type"] == "step_join_completed"))
    assert Enum.any?(events, &(&1["type"] == "step_sink_completed"))

    RedisStore.delete_job(job_id)
  end

  test "workflow steps complete through ledger before terminal sink completes the run" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "workflow_complete_guard",
      "entrypoints" => ["step_a"],
      "flow" => %{
        "steps" => [
          %{
            "id" => "step_a",
            "run" => "step_a",
            "label" => "Step A",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 5,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
            }
          },
          %{
            "id" => "step_b",
            "run" => "step_b",
            "label" => "Step B",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 5,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
            }
          }
        ],
        "graph" => %{
          "edges" => [
            %{
              "id" => "step_a_to_step_b",
              "from" => "step_a",
              "to" => "step_b",
              "event" => "step_a_done",
              "accepts" => ["done"],
              "required" => true
            }
          ]
        }
      },
      "nodes" => [
        %{
          "node_id" => "step_a",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => WorkflowFirstRunner,
            "output_message_type" => nil
          }
        },
        %{
          "node_id" => "step_b",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => WorkflowSecondRunner,
            "output_message_type" => nil
          }
        },
        %{
          "node_id" => "report_sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "step_a", "to_node" => "step_b", "message_type" => "step_a_done"},
        %{
          "from_node" => "step_b",
          "to_node" => "report_sink",
          "message_type" => "workflow_done"
        }
      ],
      "initial_inputs" => %{"step_a" => [%{"value" => "start"}]},
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "agent_id"]) == "report_sink"
    assert get_in(job, ["result", "output", "last_message", "done"]) == true
    assert get_in(job, ["result", "output", "last_message", "payload", "from"]) == "step_a"
    assert get_in(job, ["workflow_state", "steps", "step_a", "status"]) == "completed"
    assert get_in(job, ["workflow_state", "steps", "step_b", "status"]) == "completed"

    wait_until(
      fn ->
        DeliveryChannels.depth(job_id, Delivery.coordinator_agent_id(), :control) == {:ok, 0}
      end,
      1_000
    )

    assert {:ok, 0} = DeliveryChannels.depth(job_id, Delivery.coordinator_agent_id(), :control)

    wait_until(fn -> event_count(job_id, "job_completed") == 1 end, 1_000)
    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.count(events, &(&1["type"] == "job_completed")) == 1

    RedisStore.delete_job(job_id)
  end

  test "routes emitted messages by context-aware manifest edge conditions" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "context_aware_routing_test",
      "entrypoints" => ["classifier"],
      "initial_inputs" => %{
        "classifier" => [%{"domain" => "finance", "confidence" => 0.94}]
      },
      "nodes" => [
        %{
          "node_id" => "classifier",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{"module" => ContextRouterAgent}
        },
        %{
          "node_id" => "finance_sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        },
        %{
          "node_id" => "human_review",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [
        %{
          "edge_id" => "finance-route",
          "from_node" => "classifier",
          "to_node" => "finance_sink",
          "message_type" => "classified_request",
          "routing_mode" => "first_match",
          "conditions" => %{
            "all" => [
              %{"expr" => "${payload.domain} == \"finance\""},
              %{"expr" => "${state.confidence} >= 0.8"}
            ]
          }
        },
        %{
          "edge_id" => "human-route",
          "from_node" => "classifier",
          "to_node" => "human_review",
          "message_type" => "classified_request",
          "routing_mode" => "first_match",
          "conditions" => %{"expr" => "${state.confidence} < 0.8"}
        }
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "last_message", "domain"]) == "finance"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "route_evaluated"))

    assert Enum.any?(
             events,
             &(&1["type"] == "route_selected" and get_in(&1, ["payload", "to"]) == "finance_sink")
           )

    RedisStore.delete_job(job_id)
  end

  # These integration cases depend on isolated coordinator/runner state. The
  # release CI process currently shares live jobs across them, so keep the
  # nondeterministic local-recovery cases skipped until their fixtures are
  # isolated without weakening production behavior.
end
