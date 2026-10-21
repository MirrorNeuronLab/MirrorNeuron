defmodule MirrorNeuron.WorkflowInvocationTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore

  setup do
    {:ok, _} = Application.ensure_all_started(:mirror_neuron)
    assert {:ok, "PONG"} = Redix.command(MirrorNeuron.Redis.Connection, ["PING"])
    original_hardware = System.get_env("MN_NODE_HARDWARE_JSON")
    hardware = Jason.decode!(original_hardware || "{}")
    hardware = Map.put(hardware, "native_sdk_grpc", %{"capabilities" => ["exclusive_run_v1"]})
    System.put_env("MN_NODE_HARDWARE_JSON", Jason.encode!(hardware))

    on_exit(fn ->
      if original_hardware,
        do: System.put_env("MN_NODE_HARDWARE_JSON", original_hardware),
        else: System.delete_env("MN_NODE_HARDWARE_JSON")
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
end
