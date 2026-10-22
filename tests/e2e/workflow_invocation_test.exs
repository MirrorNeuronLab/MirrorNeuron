defmodule MirrorNeuron.WorkflowInvocationTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore

  setup do
    {:ok, _} = Application.ensure_all_started(:mirror_neuron)
    assert {:ok, "PONG"} = Redix.command(MirrorNeuron.Redis.Connection, ["PING"])
    original_hardware = System.get_env("MN_NODE_HARDWARE_JSON")
    original_namespace = System.get_env("MN_REDIS_NAMESPACE")

    delivery_settings = %{
      "MN_MESSAGE_ACK_TIMEOUT_MS" => "200",
      "MN_MESSAGE_LEASE_RENEW_MS" => "50",
      "MN_MESSAGE_DELIVERY_POLL_MS" => "20"
    }

    original_delivery_settings =
      Map.new(delivery_settings, fn {key, _} -> {key, System.get_env(key)} end)

    System.put_env(delivery_settings)
    namespace = "workflow_invocation_#{System.unique_integer([:positive])}"
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    hardware = Jason.decode!(original_hardware || "{}")
    hardware = Map.put(hardware, "native_sdk_grpc", %{"capabilities" => ["exclusive_run_v1"]})
    System.put_env("MN_NODE_HARDWARE_JSON", Jason.encode!(hardware))
    assert {:ok, _} = MirrorNeuron.Cluster.NodeState.advertise_self()

    on_exit(fn ->
      if original_hardware,
        do: System.put_env("MN_NODE_HARDWARE_JSON", original_hardware),
        else: System.delete_env("MN_NODE_HARDWARE_JSON")

      if original_namespace,
        do: System.put_env("MN_REDIS_NAMESPACE", original_namespace),
        else: System.delete_env("MN_REDIS_NAMESPACE")

      Enum.each(original_delivery_settings, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "ledger context reaches parallel subprocesses through generated step boundaries" do
    manifest = %{
      "manifest_version" => "1.0",
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "graph_id" => "invocation_identity_runtime",
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
          "agent_type" => "executor",
          "config" => worker_config("research_a_completed")
        },
        %{
          "node_id" => "analyze__research_b",
          "agent_type" => "executor",
          "config" => worker_config("research_b_completed")
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

    {nodes, manifest} = Map.pop(manifest, "nodes")
    {edges, manifest} = Map.pop(manifest, "edges")
    manifest = update_in(manifest["flow"], &Map.merge(&1, %{"nodes" => nodes, "edges" => edges}))

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 10_000)
    on_exit(fn -> RedisStore.delete_job(job_id) end)

    assert job["status"] == "completed",
           inspect(Map.take(job, ["error", "result", "workflow_state"]), limit: :infinity)

    assert get_in(job, ["workflow_state", "steps", "analyze", "status"]) == "completed"

    output = get_in(job, ["result", "output", "last_message", "outputs", "result"])
    left = output["research_a"]
    right = output["research_b"]

    assert is_binary(left["invocation_key"]) and left["invocation_key"] != "",
           inspect(output, limit: :infinity)

    assert is_binary(right["invocation_key"]) and right["invocation_key"] != ""
    refute left["invocation_key"] == right["invocation_key"]
    assert left["step_key"] == right["step_key"]
    assert is_binary(left["step_key"]) and left["step_key"] != ""
    assert left["attempt_id"] == right["attempt_id"]
    assert is_binary(left["attempt_id"]) and left["attempt_id"] != ""
  end

  defp worker_config(output_type) do
    %{
      "runner_module" => MirrorNeuron.Runner.HostLocal,
      "workflow_complete_step" => false,
      "output_message_type" => output_type,
      "command" => [
        "/bin/sh",
        "-c",
        ~S"""
        test -n "$MN_WORKFLOW_IDEMPOTENCY_KEY" &&
        test -n "$MN_WORKFLOW_STEP_IDEMPOTENCY_KEY" &&
        test -n "$MN_WORKFLOW_ATTEMPT_ID" || exit 1
        printf '{"outputs":{"invocation_key":"%s","step_key":"%s","attempt_id":"%s"},"artifacts":[],"metrics":{},"status":"completed","runtime_step_mode":"manifest_handler"}\n' "$MN_WORKFLOW_IDEMPOTENCY_KEY" "$MN_WORKFLOW_STEP_IDEMPOTENCY_KEY" "$MN_WORKFLOW_ATTEMPT_ID"
        """
      ]
    }
  end

  test "generated source collects both upstream boundaries before publishing" do
    left = compiled_step("left", [], %{"value" => "left result"})
    right = compiled_step("right", [], %{"value" => "right result"})

    publish =
      compiled_step("publish", ~w(left right), %{
        "left" => %{"$ref" => "upstream", "step_id" => "left", "path" => ["result", "value"]},
        "right" => %{"$ref" => "upstream", "step_id" => "right", "path" => ["result", "value"]}
      })

    job = run_compiled([left, right, publish], ~w(left right))
    assert get_in(job, ["workflow_state", "steps", "publish", "attempt_count"]) == 1

    assert get_in(job, ["result", "output", "last_message", "outputs", "result"]) ==
             %{"left" => "left result", "right" => "right result"}
  end

  test "child planner executes through its generated source and sink before the next step" do
    inspect_step = compiled_step("inspect", [], %{"context" => %{}})

    planner =
      compiled_step("planner", [], %{
        "child_plan" => %{
          "decision" => "stop",
          "revision" => 0,
          "reason" => "Investigation complete",
          "output" => %{"answer" => "Evidence reviewed"}
        }
      })

    report =
      compiled_step("report", ["inspect"], %{
        "answer" => %{
          "$ref" => "upstream",
          "step_id" => "inspect",
          "path" => ["result", "answer"]
        }
      })

    children = %{
      "inspect" => %{
        "planner" => "planner",
        "templates" => %{"planner" => planner.step},
        "inputs" => %{"context" => ["outputs", "result", "context"]},
        "outputs" => %{"result" => []},
        "max_rounds" => 2,
        "max_steps_per_round" => 2
      }
    }

    job =
      run_compiled([inspect_step, report], ["inspect"], children, planner.nodes, planner.edges)

    assert get_in(job, ["workflow_state", "steps", "inspect:p0", "status"]) == "completed"

    assert get_in(job, ["result", "output", "last_message", "outputs", "result"]) ==
             %{"answer" => "Evidence reviewed"}
  end

  defp compiled_step(id, upstreams, fields) do
    start = id <> "__start"
    worker = id <> "__worker"
    finish = id <> "__end"

    %{
      upstreams: upstreams,
      step: %{
        "id" => id,
        "run" => start,
        "agent_id" => start,
        "agent_ids" => [start, worker, finish]
      },
      nodes: [
        %{
          "node_id" => start,
          "agent_type" => "step_source",
          "config" => %{
            "step_id" => id,
            "required_upstreams" => upstreams,
            "fields" => fields,
            "output_message_type" => id <> "_started"
          }
        },
        %{
          "node_id" => worker,
          "agent_type" => "router",
          "config" => %{"emit_type" => id <> "_worked"}
        },
        %{
          "node_id" => finish,
          "agent_type" => "step_sink",
          "config" => %{
            "step_id" => id,
            "fields" => %{"result" => %{"$ref" => "flow_output"}},
            "output_message_type" => id <> "_completed"
          }
        }
      ],
      edges: [
        %{"from_node" => start, "to_node" => worker, "message_type" => id <> "_started"},
        %{"from_node" => worker, "to_node" => finish, "message_type" => id <> "_worked"}
      ]
    }
  end

  defp run_compiled(steps, entrypoints, children \\ %{}, extra_nodes \\ [], extra_edges \\ []) do
    last_id = List.last(steps).step["id"]

    terminal = %{
      "node_id" => "workflow__terminal",
      "agent_type" => "aggregator",
      "config" => %{"complete_after" => 1, "terminal_sink" => true, "complete_run" => true}
    }

    terminal_edge = %{
      "from_node" => last_id <> "__end",
      "to_node" => "workflow__terminal",
      "message_type" => last_id <> "_completed"
    }

    dependencies =
      for step <- steps,
          upstream <- step.upstreams,
          do: %{"from" => upstream, "to" => step.step["id"]}

    boundary_edges =
      for %{"from" => from, "to" => to} <- dependencies do
        %{
          "from_node" => from <> "__end",
          "to_node" => to <> "__start",
          "message_type" => from <> "_completed"
        }
      end

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "workflow_admission_regression",
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "entrypoints" => Enum.map(entrypoints, &(&1 <> "__start")),
      "flow" => %{
        "steps" => Enum.map(steps, & &1.step),
        "graph" => %{"edges" => dependencies},
        "child_workflows" => children,
        "nodes" => Enum.flat_map(steps, & &1.nodes) ++ extra_nodes ++ [terminal],
        "edges" =>
          Enum.flat_map(steps, & &1.edges) ++ boundary_edges ++ extra_edges ++ [terminal_edge]
      },
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest)

    on_exit(fn ->
      MirrorNeuron.Runtime.cancel_job(job_id)
      MirrorNeuron.Runtime.NodeAdmission.retire(job_id)
      RedisStore.delete_job(job_id)
    end)

    case MirrorNeuron.Runtime.await_completion(job_id, 10_000) do
      {:ok, job} ->
        assert job["status"] == "completed",
               inspect(Map.take(job, ["error", "result", "workflow_state"]), limit: :infinity)

        job

      error ->
        state = :sys.get_state(MirrorNeuron.Runtime.Naming.via_job(job_id))

        source =
          :sys.get_state(MirrorNeuron.Runtime.Naming.via_agent(job_id, last_id <> "__start"))

        statuses =
          Map.new(state.workflow_state["steps"], fn {id, step} -> {id, step["status"]} end)

        collection = Map.take(source.local_state, [:attempt_id, :dispatched, :upstream_outputs])
        flunk(inspect({error, statuses, collection}, limit: :infinity))
    end
  end
end
