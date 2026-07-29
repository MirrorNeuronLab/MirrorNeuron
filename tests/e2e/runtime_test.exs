defmodule MirrorNeuron.RuntimeTest do
  use ExUnit.Case

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{AgentWorker, Delivery}
  alias MirrorNeuron.ServiceRegistry

  defmodule BundlePathEchoRunner do
    def run(_payload, _config, opts) do
      bundle_root = Keyword.get(opts, :bundle_root)
      manifest_path = Keyword.get(opts, :manifest_path)
      payloads_path = Keyword.get(opts, :payloads_path)

      {:ok,
       %{
         "sandbox_name" => "bundle-path-echo",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "complete_run" => %{
               "bundle_root" => bundle_root,
               "manifest_path" => manifest_path,
               "payloads_path" => payloads_path,
               "bundle_exists" => File.dir?(bundle_root || ""),
               "manifest_exists" => File.exists?(manifest_path || ""),
               "payloads_exists" => File.dir?(payloads_path || "")
             }
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule StreamProducerRunner do
    def run(_payload, _config, opts) do
      job_id = Keyword.fetch!(opts, :job_id)
      agent_id = Keyword.fetch!(opts, :agent_id)

      {:ok,
       %{
         "sandbox_name" => "producer",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "emit_messages" => [
               %{
                 "type" => "telemetry_chunk",
                 "body" => "{\"value\":10}\n",
                 "class" => "stream",
                 "content_type" => "application/x-ndjson",
                 "content_encoding" => "identity",
                 "stream" => %{
                   "stream_id" => "#{job_id}:#{agent_id}",
                   "seq" => 1,
                   "open" => true,
                   "close" => false
                 }
               },
               %{
                 "type" => "telemetry_chunk",
                 "body" => "{\"value\":90}\n",
                 "class" => "stream",
                 "content_type" => "application/x-ndjson",
                 "content_encoding" => "identity",
                 "stream" => %{
                   "stream_id" => "#{job_id}:#{agent_id}",
                   "seq" => 2,
                   "open" => false,
                   "close" => true,
                   "eof" => true
                 }
               }
             ]
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule StreamDetectorRunner do
    def run(_payload, _config, opts) do
      message = Keyword.fetch!(opts, :message)
      state = Keyword.get(opts, :agent_state, %{})
      count = Map.get(state, "count", 0) + 1

      completion =
        if get_in(message, ["stream", "close"]) do
          %{"chunks_received" => count, "peak_detected" => true}
        end

      {:ok,
       %{
         "sandbox_name" => "detector",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "next_state" => %{"count" => count},
             "events" => [%{"type" => "stream_chunk_processed", "payload" => %{"count" => count}}],
             "complete_run" => completion
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule SlowBackpressureRunner do
    def run(payload, _config, _opts) do
      Process.sleep(300)

      {:ok,
       %{
         "sandbox_name" => "slow-backpressure",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "events" => [
               %{
                 "type" => "slow_event_processed",
                 "payload" => %{"value" => Map.get(payload, "value")}
               }
             ]
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule CrashOnceCounter do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> 0 end, name: __MODULE__)
    end

    def next_invocation do
      Agent.get_and_update(__MODULE__, fn count ->
        next = count + 1
        {next, next}
      end)
    end

    def invocations, do: Agent.get(__MODULE__, & &1)
  end

  defmodule CrashOnceRunner do
    def run(_payload, _config, _opts) do
      case CrashOnceCounter.next_invocation() do
        1 ->
          Process.sleep(10_000)

          {:ok,
           %{
             "sandbox_name" => "crash-once",
             "exit_code" => 0,
             "stdout" => "{}",
             "stderr" => "",
             "logs" => ""
           }}

        invocation ->
          {:ok,
           %{
             "sandbox_name" => "crash-once",
             "exit_code" => 0,
             "stdout" =>
               Jason.encode!(%{
                 "complete_run" => %{
                   "recovered" => true,
                   "invocation" => invocation
                 }
               }),
             "stderr" => "",
             "logs" => ""
           }}
      end
    end
  end

  defmodule CrashTwiceCounter do
    @key __MODULE__

    def init do
      :persistent_term.put(@key, :atomics.new(1, []))
      :atomics.put(:persistent_term.get(@key), 1, 0)
      :ok
    end

    def next_invocation do
      atomics = :persistent_term.get(@key)
      :atomics.add_get(atomics, 1, 1)
    end

    def invocations do
      @key
      |> :persistent_term.get()
      |> :atomics.get(1)
    end
  end

  defmodule CrashTwiceRunner do
    def run(_payload, _config, _opts) do
      case CrashTwiceCounter.next_invocation() do
        invocation when invocation <= 2 ->
          Process.sleep(10_000)

          {:ok,
           %{
             "sandbox_name" => "crash-twice",
             "exit_code" => 0,
             "stdout" => "{}",
             "stderr" => "",
             "logs" => ""
           }}

        invocation ->
          {:ok,
           %{
             "sandbox_name" => "crash-twice",
             "exit_code" => 0,
             "stdout" =>
               Jason.encode!(%{
                 "complete_run" => %{
                   "recovered" => true,
                   "invocation" => invocation
                 }
               }),
             "stderr" => "",
             "logs" => ""
           }}
      end
    end
  end

  defmodule DelayedCompleteRunner do
    def run(_payload, _config, _opts) do
      Process.sleep(1_000)

      {:ok,
       %{
         "sandbox_name" => "delayed-complete",
         "exit_code" => 0,
         "stdout" => Jason.encode!(%{"complete_run" => %{"done" => true}}),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule LongSleepRunner do
    def run(_payload, _config, _opts) do
      Process.sleep(30_000)

      {:ok,
       %{
         "sandbox_name" => "long-sleep",
         "exit_code" => 0,
         "stdout" => Jason.encode!(%{"complete_run" => %{"done" => true}}),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule PauseResumeInvocationCounter do
    @key __MODULE__

    def reset do
      :persistent_term.put(@key, :atomics.new(1, []))
      :ok
    end

    def next do
      @key
      |> :persistent_term.get()
      |> :atomics.add_get(1, 1)
    end
  end

  defmodule PauseResumeRunner do
    def run(_payload, _config, _opts) do
      case PauseResumeInvocationCounter.next() do
        1 ->
          Process.sleep(30_000)

          {:ok,
           %{
             "sandbox_name" => "pause-resume-interrupted",
             "exit_code" => 0,
             "stdout" => "{}",
             "stderr" => "",
             "logs" => ""
           }}

        invocation ->
          {:ok,
           %{
             "sandbox_name" => "pause-resume-completed",
             "exit_code" => 0,
             "stdout" =>
               Jason.encode!(%{
                 "emit_messages" => [
                   %{"type" => "workflow_done", "body" => %{"resumed" => true}}
                 ],
                 "complete_step" => %{"resumed" => true, "invocation" => invocation}
               }),
             "stderr" => "",
             "logs" => ""
           }}
      end
    end
  end

  defmodule SafeRetryRunner do
    def run(payload, _config, opts) do
      {:ok,
       %{
         "sandbox_name" => "safe-retry",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "complete_run" => %{
               "retried" => true,
               "payload" => payload,
               "attempt" => Keyword.get(opts, :attempt)
             }
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule HibernateRetryCounter do
    @key __MODULE__

    def init do
      :persistent_term.put(@key, :atomics.new(1, []))
      :atomics.put(:persistent_term.get(@key), 1, 0)
      :ok
    end

    def next_invocation do
      @key
      |> :persistent_term.get()
      |> :atomics.add_get(1, 1)
    end

    def invocations do
      @key
      |> :persistent_term.get()
      |> :atomics.get(1)
    end
  end

  defmodule HibernateRetryRunner do
    def run(payload, _config, opts) do
      case HibernateRetryCounter.next_invocation() do
        1 ->
          {:error, %{"error" => "resource temporarily unavailable after wake"}}

        invocation ->
          {:ok,
           %{
             "sandbox_name" => "hibernate-retry",
             "exit_code" => 0,
             "stdout" =>
               Jason.encode!(%{
                 "complete_run" => %{
                   "invocation" => invocation,
                   "message_id" => opts |> Keyword.fetch!(:message) |> MirrorNeuron.Message.id(),
                   "payload" => payload
                 }
               }),
             "stderr" => "",
             "logs" => ""
           }}
      end
    end
  end

  defmodule ProfiledCompleteRunner do
    def run(_payload, config, _opts) do
      {:ok,
       %{
         "sandbox_name" => "profiled-complete",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "complete_run" => %{
               "profile" => Map.get(config, "execution_profile"),
               "image" => Map.get(config, "from")
             }
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule WorkflowFirstRunner do
    def run(_payload, _config, _opts) do
      {:ok,
       %{
         "sandbox_name" => "workflow-first",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "emit_messages" => [
               %{
                 "type" => "step_a_done",
                 "body" => %{"from" => "step_a"}
               }
             ],
             "complete_step" => %{"from" => "step_a"}
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule WorkflowSecondRunner do
    def run(payload, _config, _opts) do
      {:ok,
       %{
         "sandbox_name" => "workflow-second",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "emit_messages" => [
               %{
                 "type" => "workflow_done",
                 "body" => %{"done" => true, "payload" => payload}
               }
             ],
             "complete_step" => %{"done" => true, "payload" => payload}
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule AllocationEchoRunner do
    def run(_payload, config, _opts) do
      environment = Map.get(config, "environment", %{})

      {:ok,
       %{
         "sandbox_name" => "allocation-echo",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "complete_run" => %{
               "allocation" => Map.get(config, "__mirror_neuron_allocation"),
               "env" => environment
             }
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule ExplicitCheckpointAgent do
    use MirrorNeuron.AgentTemplate

    @impl true
    def init(_node), do: {:ok, %{messages: 0}}

    @impl true
    def handle_message(_message, state, _context) do
      next_state = %{state | messages: state.messages + 1}

      {:ok, next_state,
       [
         {:checkpoint,
          %{
            "agent_id" => "checkpoint_agent",
            "processed_messages" => next_state.messages,
            "metadata" => %{"explicit_checkpoint" => true}
          }}
       ]}
    end
  end

  defmodule DurableCounterAgent do
    use MirrorNeuron.AgentTemplate

    @impl true
    def init(node) do
      {:ok, %{count: 0, target: Map.get(node.config, "target", 12), seen_ids: []}}
    end

    @impl true
    def handle_message(message, state, _context) do
      payload = payload(message) || %{}
      message_id = Map.get(payload, "id")

      cond do
        is_nil(message_id) ->
          {:ok, state, [{:event, :counter_control_ignored, %{"count" => state.count}}]}

        message_id in state.seen_ids ->
          {:ok, state,
           [{:event, :counter_duplicate_ignored, %{"id" => message_id, "count" => state.count}}]}

        true ->
          seen_ids = state.seen_ids ++ [message_id]

          next_state = %{state | count: state.count + 1, seen_ids: seen_ids}

          actions = [{:event, :counter_step_completed, %{"count" => next_state.count}}]

          actions =
            if next_state.count >= next_state.target do
              actions ++
                [
                  {:complete_run,
                   %{
                     "count" => next_state.count,
                     "seen_ids" => next_state.seen_ids
                   }}
                ]
            else
              actions
            end

          {:ok, next_state, actions}
      end
    end
  end

  defmodule ContextRouterAgent do
    use MirrorNeuron.AgentTemplate

    @impl true
    def init(_node), do: {:ok, %{domain: nil, confidence: 0.0}}

    @impl true
    def handle_message(message, _state, _context) do
      payload = payload(message) || %{}
      domain = Map.get(payload, "domain", "general")
      confidence = Map.get(payload, "confidence", 0.0)
      next_state = %{domain: domain, confidence: confidence}

      {:ok, next_state,
       [
         {:emit, "classified_request", %{"domain" => domain, "confidence" => confidence}},
         {:event, :classification_state_updated,
          %{"domain" => domain, "confidence" => confidence}}
       ]}
    end
  end

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} ->
        :ok

      _ ->
        raise "Redis must be running for runtime tests"
    end
  end

  setup do
    original_health = Application.get_env(:mirror_neuron, :job_health_check_interval_ms)
    original_heartbeat = Application.get_env(:mirror_neuron, :agent_heartbeat_interval_ms)
    original_resource_admission_env = System.get_env("MN_RESOURCE_ADMISSION_ENABLED")
    original_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    original_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    namespace = "runtime_test_#{System.unique_integer([:positive])}"

    Application.put_env(:mirror_neuron, :job_health_check_interval_ms, 100)
    Application.put_env(:mirror_neuron, :agent_heartbeat_interval_ms, 100)
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_RESOURCE_ADMISSION_ENABLED", "false")
    System.put_env("MN_REDIS_NAMESPACE", namespace)

    on_exit(fn ->
      cleanup_runtime_namespace()
      cleanup_namespace(namespace)
      restore_application_env(:redis_namespace, original_namespace)
      restore_system_env("MN_REDIS_NAMESPACE", original_system_namespace)

      if original_health == nil do
        Application.delete_env(:mirror_neuron, :job_health_check_interval_ms)
      else
        Application.put_env(:mirror_neuron, :job_health_check_interval_ms, original_health)
      end

      if original_heartbeat == nil do
        Application.delete_env(:mirror_neuron, :agent_heartbeat_interval_ms)
      else
        Application.put_env(:mirror_neuron, :agent_heartbeat_interval_ms, original_heartbeat)
      end

      if original_resource_admission_env == nil do
        System.delete_env("MN_RESOURCE_ADMISSION_ENABLED")
      else
        System.put_env(
          "MN_RESOURCE_ADMISSION_ENABLED",
          original_resource_admission_env
        )
      end
    end)

    :ok
  end

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
        RedisStore.delivery_pending_count(job_id, Delivery.coordinator_agent_id()) == {:ok, 0}
      end,
      1_000
    )

    assert {:ok, 0} = RedisStore.delivery_pending_count(job_id, Delivery.coordinator_agent_id())

    wait_until(fn -> event_count(job_id, "job_completed") == 1 end, 1_000)
    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.count(events, &(&1["type"] == "job_completed")) == 1

    RedisStore.delete_job(job_id)
  end

  test "deploys a service, stages a canary update, and promotes it" do
    key = "deploy-runtime-#{System.unique_integer([:positive])}"
    manifest_v1 = deployment_service_manifest(key, "v1")

    assert {:ok, first} = deploy_manifest(manifest_v1, deployment_key: key)
    assert first["status"] == "successful"
    job_id = first["job_id"]

    assert {:ok, deployment} = MirrorNeuron.get_deployment(key)
    assert deployment["stable_version"] == "1"
    assert deployment["stable_job_id"] == job_id

    manifest_v2 =
      deployment_service_manifest(key, "v2")
      |> put_in(["policies", "update"], %{
        "strategy" => "canary",
        "canary" => 1,
        "max_parallel" => 1,
        "min_healthy_ms" => 0,
        "healthy_deadline_ms" => 1_000
      })

    assert {:ok, staged} = update_deployment(key, manifest_v2)
    assert staged["status"] == "awaiting_promotion"
    assert staged["deployment"]["target_version"] == "2"

    assert {:ok, promoted} = MirrorNeuron.promote_deployment(key)
    assert promoted["status"] == "successful"
    assert promoted["deployment"]["stable_version"] == "2"

    assert {:ok, services} = ServiceRegistry.resolve("deploy-runtime-api")
    assert Enum.any?(services, &(&1["deployment_version"] == "2"))

    MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  test "passes scheduler allocation metadata into executor runtime environment" do
    node_name = to_string(Node.self())
    volume_root = Path.join(System.tmp_dir!(), "mn-allocation-volume")
    File.mkdir_p!(volume_root)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "allocation_env_runtime_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"start" => true}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => AllocationEchoRunner,
            "output_message_type" => nil
          },
          "resources" => %{
            "devices" => [%{"kind" => "gpu", "driver" => "cuda", "min_memory_mb" => 1024}],
            "ports" => [%{"label" => "api", "port" => 18_080, "protocol" => "tcp"}],
            "volumes" => [
              %{
                "name" => "models",
                "source" => volume_root,
                "target" => "/models",
                "mode" => "ro"
              }
            ]
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    fake_node = %{
      "name" => node_name,
      "status" => "healthy",
      "runtime_drivers" => ["host_local"],
      "host_paths" => [System.tmp_dir!()],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 8},
        "memory" => %{"available_mb" => 16_384},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => [
          %{
            "id" => "GPU-runtime",
            "index" => 0,
            "name" => "NVIDIA Runtime GPU",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 8192,
            "memory_free_mb" => 4096,
            "capabilities" => ["gpu", "cuda", "nvidia"]
          }
        ]
      }
    }

    assert {:ok, job_id, job} =
             run_manifest(manifest,
               nodes: [fake_node],
               lookup_node_state: false,
               await: true,
               timeout: 2_000
             )

    assert job["status"] == "completed"

    assert get_in(job, ["result", "output", "allocation", "devices", Access.at(0), "id"]) ==
             "GPU-runtime"

    assert get_in(job, ["result", "output", "env", "MN_ALLOCATED_DEVICE_IDS"]) == "GPU-runtime"
    assert get_in(job, ["result", "output", "env", "CUDA_VISIBLE_DEVICES"]) == "0"
    assert get_in(job, ["result", "output", "env", "MN_PORT_API"]) == "18080"
    assert get_in(job, ["result", "output", "env", "MN_VOLUME_MODELS"]) == volume_root

    RedisStore.delete_job(job_id)
    File.rm_rf(volume_root)
  end

  test "agent workers materialize archived bundles when original bundle path is unavailable" do
    job_id = "remote-bundle-agent-#{System.unique_integer([:positive])}"
    bundle_root = Path.join(System.tmp_dir!(), "#{job_id}-bundle")
    File.mkdir_p!(Path.join(bundle_root, "payloads"))

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => job_id,
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => BundlePathEchoRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => []
    }

    File.write!(Path.join(bundle_root, "manifest.json"), Jason.encode!(flow_manifest(manifest)))

    {:ok, bundle} = MirrorNeuron.JobBundle.load(bundle_root)
    manifest_ref = Runtime.bundle_ref(bundle.manifest, bundle)
    missing_root = Path.join(System.tmp_dir!(), "#{job_id}-missing")
    File.rm_rf!(missing_root)

    node = %{
      node_id: "worker",
      agent_type: "executor",
      role: nil,
      type: "generic",
      config: %{
        "runner_module" => BundlePathEchoRunner,
        "output_message_type" => nil
      }
    }

    runtime_context = %{
      bundle_root: missing_root,
      manifest_path: Path.join(missing_root, "manifest.json"),
      payloads_path: Path.join(missing_root, "payloads"),
      manifest_ref: manifest_ref,
      scheduler: %{"placements" => []},
      artifact_refs: []
    }

    {:ok, pid} =
      AgentWorker.start_link({job_id, node, [], [], self(), runtime_context, nil})

    message =
      Message.new(job_id, "runtime", "worker", "init", %{"start" => true}, class: "command")

    GenServer.cast(pid, {:deliver, message})

    consumer = Delivery.consumer_id(job_id, Delivery.coordinator_agent_id())

    delivery =
      Enum.reduce_while(1..100, nil, fn _, _acc ->
        case Delivery.read(job_id, Delivery.coordinator_agent_id(), consumer) do
          {:ok, [delivery]} ->
            if get_in(delivery.message, ["body", "kind"]) == "agent_completed_run" do
              {:halt, delivery}
            else
              assert :ok =
                       Delivery.ack(
                         job_id,
                         Delivery.coordinator_agent_id(),
                         consumer,
                         delivery
                       )

              {:cont, nil}
            end

          {:ok, []} ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    assert delivery
    result = get_in(delivery.message, ["body", "result"])
    assert result["bundle_root"] == manifest_ref["cache_path"]
    assert result["manifest_path"] == Path.join(manifest_ref["cache_path"], "manifest.json")
    assert result["payloads_path"] == Path.join(manifest_ref["cache_path"], "payloads")
    assert result["bundle_exists"] == true
    assert result["manifest_exists"] == true
    assert result["payloads_exists"] == true

    assert :ok =
             Delivery.ack(
               job_id,
               Delivery.coordinator_agent_id(),
               consumer,
               delivery
             )

    GenServer.stop(pid)
    RedisStore.delete_job(job_id)
    File.rm_rf!(bundle_root)
  end

  test "single node jobs use shared bundle cache as runtime context" do
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")

    shared_root =
      Path.join(System.tmp_dir!(), "mn-shared-runtime-#{System.unique_integer([:positive])}")

    System.delete_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)

    bundle_dir =
      Path.join(System.tmp_dir!(), "mn-shared-bundle-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
      File.rm_rf!(shared_root)
      File.rm_rf!(bundle_dir)
    end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "shared_bundle_context_runtime_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"start" => true}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => BundlePathEchoRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => []
    }

    File.mkdir_p!(Path.join(bundle_dir, "payloads"))
    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(flow_manifest(manifest)))

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(bundle_dir, await: true, timeout: 2_000)

    output = bundle_echo_output(job)
    bundle_root = output["bundle_root"]
    assert job["status"] == "completed"
    assert String.starts_with?(bundle_root, Path.join(shared_root, "bundle_cache") <> "/")
    assert output["bundle_exists"] == true
    assert output["manifest_exists"] == true
    assert output["payloads_exists"] == true

    RedisStore.delete_job(job_id)
  end

  test "single node jobs use Redis-backed cache after the source bundle is removed" do
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")

    root =
      Path.join(System.tmp_dir!(), "mn-redis-cache-runtime-#{System.unique_integer([:positive])}")

    cache_dir = Path.join(root, "cache")
    bundle_dir = Path.join(root, "request-bundle")
    System.put_env("MN_BUNDLE_CACHE_DIR", cache_dir)

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
      File.rm_rf!(root)
    end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "redis_bundle_context_runtime_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"start" => true}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => BundlePathEchoRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => []
    }

    File.mkdir_p!(Path.join(bundle_dir, "payloads"))
    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(flow_manifest(manifest)))

    assert {:ok, job_id} = MirrorNeuron.run_manifest(bundle_dir, await: false)
    File.rm_rf!(bundle_dir)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)

    output = bundle_echo_output(job)
    assert job["status"] == "completed"
    assert get_in(job, ["manifest_ref", "bundle_storage"]) == "redis"
    assert String.starts_with?(output["bundle_root"], cache_dir <> "/")
    assert output["bundle_exists"] == true
    assert output["manifest_exists"] == true
    assert output["payloads_exists"] == true
    refute File.exists?(bundle_dir)

    RedisStore.delete_job(job_id)
  end

  test "omitted recovery policy persists auto request with local effective policy on a single node" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "auto_reliability_single_node_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{"ingress" => [%{"text" => "hello"}]},
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "done"}
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
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "sink", "message_type" => "done"}
      ]
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job["status"] == "completed"
    assert job["requested_recovery_policy"] == "auto"
    assert job["recovery_policy"] == "local_restart"
    assert get_in(job, ["reliability", "mode"]) == "single_node"
    assert get_in(job, ["reliability", "effective_recovery_policy"]) == "local_restart"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "reliability_strategy_resolved"))

    RedisStore.delete_job(job_id)
  end

  test "explicit cluster recovery degrades to local restart on a single node and emits metadata" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cluster_reliability_degraded_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{"ingress" => [%{"text" => "hello"}]},
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "done"}
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
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "sink", "message_type" => "done"}
      ],
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job["requested_recovery_policy"] == "cluster_recover"
    assert job["recovery_policy"] == "local_restart"
    assert job["reliability_degraded"] == true
    assert get_in(job, ["reliability", "degraded"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_reliability_degraded"))

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
  test "queues messages while paused and completes after resume" do
    manifest = pause_resume_dag_manifest("pause_resume_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_paused?(job_id, "sink") end)
    assert_runtime_workflow_manifest(job_id)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved while paused"}
             })

    wait_until(fn -> agent_pending_count(job_id, "sink") == 1 end)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "completed"
    assert_runtime_workflow_manifest(job_id)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert_event_before(events, "job_pausing", "job_paused")
    assert_event_before(events, "job_paused", "job_resumed")
    assert_event_before(events, "job_resumed", "job_completed")

    RedisStore.delete_job(job_id)
  end

  test "resume is idempotent for an already running job" do
    manifest = pause_resume_dag_manifest("resume_running_idempotent_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, %{"status" => "running"}} = MirrorNeuron.inspect_job(job_id)
    assert_runtime_workflow_manifest(job_id)

    cleanup_runtime_job(job_id)
  end

  test "pause is idempotent for an already paused job" do
    manifest = pause_resume_dag_manifest("pause_idempotent_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, %{"status" => "paused"}} = MirrorNeuron.inspect_job(job_id)

    cleanup_runtime_job(job_id)
  end

  test "resume restarts an interrupted workflow agent and immediately reclaims its delivery" do
    PauseResumeInvocationCounter.reset()

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "pause_resume_inflight_workflow_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"work" => "resume"}]},
      "flow" => %{
        "steps" => [
          %{
            "id" => "worker",
            "run" => "worker",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 60,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
            }
          }
        ],
        "graph" => %{"edges" => []}
      },
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => PauseResumeRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
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
      "edges" => [
        %{"from_node" => "worker", "to_node" => "sink", "message_type" => "workflow_done"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)
    wait_until(fn -> event_count(job_id, "agent_message_received") >= 1 end, 2_000)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_unregistered?(job_id, "worker") end, 2_000)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "last_message", "resumed"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert_event_before(events, "job_paused", "job_resumed")
    assert_event_before(events, "job_resumed", "job_completed")

    RedisStore.delete_job(job_id)
  end

  test "pause and resume retain exactly one coordinator health timer" do
    Application.put_env(:mirror_neuron, :job_health_check_interval_ms, 10_000)
    manifest = pause_resume_dag_manifest("pause_resume_health_timer_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)

    coordinator = job_coordinator_pid(job_id)
    first_ref = :sys.get_state(coordinator).health_check_timer_ref
    assert is_integer(Process.read_timer(first_ref))

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)

    second_ref = :sys.get_state(coordinator).health_check_timer_ref
    refute second_ref == first_ref
    assert Process.read_timer(first_ref) == false
    assert is_integer(Process.read_timer(second_ref))

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)

    third_ref = :sys.get_state(coordinator).health_check_timer_ref
    refute third_ref == second_ref
    assert Process.read_timer(second_ref) == false
    assert is_integer(Process.read_timer(third_ref))

    cleanup_runtime_job(job_id)
  end

  test "paused owner loss requires a clean attempt and discards queued attempt work" do
    manifest = pause_resume_dag_manifest("pause_resume_recovery_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_paused?(job_id, "sink") end)
    assert_runtime_workflow_manifest(job_id)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved across restart"}
             })

    wait_until(fn -> agent_pending_count(job_id, "sink") == 1 end)

    old_coordinator = job_coordinator_pid(job_id)
    Process.exit(old_coordinator, :kill)

    wait_until(fn -> not Process.alive?(old_coordinator) end, 3_000)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 3_000)

    assert {:ok, paused_job} = MirrorNeuron.inspect_job(job_id)
    assert paused_job["status"] == "paused"
    assert paused_job["recovery_mode"] == "clean_restart"
    assert paused_job["recovery_requires_review"] == true

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)

    wait_until(
      fn ->
        with {:ok, job} <- MirrorNeuron.inspect_job(job_id) do
          job["status"] == "running" and job["attempt"] == 2 and
            job["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "sink")
        else
          _ -> false
        end
      end,
      3_000
    )

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved on clean attempt"}
             })

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert job["attempt"] == 2

    assert get_in(job, ["result", "output", "last_message", "text"]) ==
             "approved on clean attempt"

    assert_runtime_workflow_manifest(job_id)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_paused_for_manual_restart"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))

    RedisStore.delete_job(job_id)
  end

  test "manual resume pauses and restarts a running orphaned job after local process loss" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "manual_resume_running_orphan_test",
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

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, %{"status" => "running"}} = MirrorNeuron.inspect_job(job_id)
    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    wait_until(fn -> running_status?(job_id) and job_runner_pid(job_id, false) != nil end, 3_000)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert job["attempt"] == 2
    assert job["lease_epoch"] > first_epoch
    assert job["recovery_mode"] == "clean_restart"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_paused_for_manual_resume"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))

    cleanup_runtime_job(job_id)
  end

  test "startup scan starts a clean safe attempt from declared inputs" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_reboot_resume_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{
            "module" => DurableCounterAgent,
            "target" => 8,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    send_counter_messages(job_id, 1..5)
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 5 end, 1_000)

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, job_after_stop} = MirrorNeuron.inspect_job(job_id)
    assert job_after_stop["status"] == "running"
    refute get_in(job_after_stop, ["result", "agent_id"]) == "job_runner"

    assert {:ok, result} = MirrorNeuron.recover_unfinished_jobs(reason: "test_startup_scan")
    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    wait_until(
      fn ->
        with {:ok, job} <- MirrorNeuron.inspect_job(job_id) do
          job["status"] == "running" and job["attempt"] == 2 and
            job["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "counter")
        else
          _ -> false
        end
      end,
      3_000
    )

    send_counter_messages(job_id, 1..8)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "count"]) == 8
    assert get_in(job, ["result", "output", "seen_ids"]) == Enum.to_list(1..8)

    assert job["attempt"] == 2
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 13 end, 1_000)
    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))
    assert Enum.count(events, &(&1["type"] == "counter_step_completed")) == 13

    RedisStore.delete_job(job_id)
  end

  test "graceful runtime shutdown keeps a running job recoverable on startup scan" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_graceful_runtime_restart_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{
            "module" => DurableCounterAgent,
            "target" => 6,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    send_counter_messages(job_id, 1..3)
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 3 end, 2_000)

    old_coordinator = job_coordinator_pid(job_id)
    :ok = GenServer.stop(old_coordinator, :normal, 1_000)

    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)
    wait_until(fn -> match?({:ok, nil}, RedisStore.get_lease("job:#{job_id}")) end, 2_000)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    refute get_in(job, ["result", "agent_id"]) == "job_runner"

    assert {:ok, result} =
             MirrorNeuron.recover_unfinished_jobs(reason: "test_graceful_restart_scan")

    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    wait_until(
      fn ->
        with {:ok, restarted} <- MirrorNeuron.inspect_job(job_id) do
          restarted["status"] == "running" and restarted["attempt"] == 2 and
            restarted["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "counter")
        else
          _ -> false
        end
      end,
      3_000
    )

    send_counter_messages(job_id, 1..6)

    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert completed["attempt"] == 2
    assert get_in(completed, ["result", "output", "count"]) == 6
    assert get_in(completed, ["result", "output", "seen_ids"]) == Enum.to_list(1..6)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_recovery_scheduled"))
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))

    RedisStore.delete_job(job_id)
  end

  test "startup scan repairs a missing job index before recovery" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_reboot_index_repair_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{
            "module" => DurableCounterAgent,
            "target" => 3,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, first_job} = MirrorNeuron.inspect_job(job_id)
    first_epoch = first_job["lease_epoch"]

    send_counter_messages(job_id, 1..1)
    wait_until(fn -> event_count(job_id, "counter_step_completed") == 1 end, 1_000)

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SREM",
               redis_key(["jobs"]),
               job_id
             ])

    assert {:ok, result} = MirrorNeuron.recover_unfinished_jobs(reason: "test_index_repair")
    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    wait_until(
      fn ->
        with {:ok, restarted} <- MirrorNeuron.inspect_job(job_id) do
          restarted["status"] == "running" and restarted["attempt"] == 2 and
            restarted["lease_epoch"] > first_epoch and job_coordinator_registered?(job_id) and
            agent_registered?(job_id, "counter")
        else
          _ -> false
        end
      end,
      3_000
    )

    send_counter_messages(job_id, 1..3)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert job["attempt"] == 2
    assert get_in(job, ["result", "output", "count"]) == 3
    assert get_in(job, ["result", "output", "seen_ids"]) == Enum.to_list(1..3)

    wait_until(fn -> event_count(job_id, "counter_step_completed") == 4 end, 1_000)
    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.count(events, &(&1["type"] == "counter_step_completed")) == 4

    RedisStore.delete_job(job_id)
  end

  test "startup scan recovers jobs falsely marked failed by runner shutdown" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "false_failed_runner_recovery_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 123}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => config
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "false-failed")
    cleanup_job_on_exit(job_id)

    assert {:ok, job} = RedisStore.fetch_job(job_id)

    assert {:ok, _job} =
             RedisStore.persist_job(
               job_id,
               Map.merge(job, %{
                 "status" => "failed",
                 "result" => %{
                   "agent_id" => "job_runner",
                   "error" => "job coordinator exited before terminal state",
                   "reason" => ":normal"
                 }
               })
             )

    assert {:ok, recovered} = MirrorNeuron.recover_job(job_id)
    assert recovered.action in [:started, :already_running]

    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert get_in(completed, ["result", "output", "payload", "value"]) == 123
    assert get_in(completed, ["result", "output", "retried"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))

    RedisStore.delete_job(job_id)
  end

  test "startup scan keeps real failed jobs terminal" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "real_failed_terminal_recovery_guard_test",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "role" => "root_coordinator",
          "config" => %{"complete_after" => 1, "terminal_sink" => true, "complete_run" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "real-failed")
    assert {:ok, job} = RedisStore.fetch_job(job_id)

    assert {:ok, _job} =
             RedisStore.persist_job(
               job_id,
               Map.merge(job, %{
                 "status" => "failed",
                 "result" => %{"agent_id" => "sink", "error" => "actual workflow failure"}
               })
             )

    assert {:ok, %{action: :skipped, reason: "job is failed"}} = MirrorNeuron.recover_job(job_id)
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, still_failed} = MirrorNeuron.inspect_job(job_id)
    assert still_failed["status"] == "failed"
    assert get_in(still_failed, ["result", "error"]) == "actual workflow failure"

    RedisStore.delete_job(job_id)
  end

  test "local recovery redoes declared inputs when the manifest is explicitly safe" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "safe_inflight_retry_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 42}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => config
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "safe-retry")

    assert {:ok, %{action: :started}} = MirrorNeuron.recover_job(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "payload", "value"]) == 42
    assert get_in(job, ["result", "output", "retried"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.any?(events, &(&1["type"] == "sandbox_job_completed"))

    RedisStore.delete_job(job_id)
  end

  test "lease loss fences the old attempt and redoes safe declared input" do
    {:ok, counter_pid} = start_supervised(CrashOnceCounter)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "hibernate_retry_recovery_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 42}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => CrashOnceRunner,
            "safe_to_retry" => true,
            "max_attempts" => 1,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => 3,
          "interval_ms" => 60_000,
          "delay_ms" => 2_000,
          "delay_function" => "constant",
          "max_delay_ms" => 2_000,
          "mode" => "fail"
        }
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)

    wait_until(fn -> CrashOnceCounter.invocations() == 1 end, 3_000)

    assert {:ok, job_before_recovery} = RedisStore.fetch_job(job_id)
    assert job_before_recovery["attempt"] == 1
    first_epoch = job_before_recovery["lease_epoch"]
    first_owner = job_before_recovery["lease_owner"]

    assert :ok = RedisStore.release_fenced_lease("job:#{job_id}", first_owner, first_epoch)

    [{runner_pid, _meta}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id})

    send(runner_pid, :renew_lease)

    wait_until(fn -> not Process.alive?(runner_pid) end, 3_000)

    assert {:ok, recovery} = MirrorNeuron.recover_unfinished_jobs(reason: "hibernate_test")

    assert Enum.any?(
             recovery.jobs,
             &(&1.job_id == job_id and &1.action in [:started, :already_running])
           )

    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 6_000)
    assert completed["status"] == "completed"
    assert completed["attempt"] == 2
    assert get_in(completed, ["result", "output", "invocation"]) == 2
    assert get_in(completed, ["result", "output", "recovered"]) == true
    assert completed["lease_epoch"] > first_epoch

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_lease_lost"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" and &1["attempt"] == 2))
    refute Enum.any?(events, &(&1["type"] == "agent_policy_action_restored"))

    GenServer.stop(counter_pid)
    RedisStore.delete_job(job_id)
  end

  test "local recovery does not start a duplicate runner while an active lease exists" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "active_lease_recovery_guard_test",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "role" => "root_coordinator",
          "config" => %{"complete_after" => 1, "terminal_sink" => true, "complete_run" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "active-lease")
    {:ok, lease} = RedisStore.acquire_fenced_lease("job:#{job_id}", "other-runtime", 10_000)

    assert {:ok, %{action: :skipped, reason: "job lease is still active"}} =
             MirrorNeuron.recover_job(job_id)

    assert job_runner_pid(job_id, false) == nil
    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert is_nil(job["recovery_status"])

    RedisStore.release_fenced_lease("job:#{job_id}", "other-runtime", lease["epoch"])
    RedisStore.delete_job(job_id)
  end

  test "manual_recover policy pauses a safe unfinished run until the operator resumes it" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "manual_policy_recovery_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 99}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => config
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "manual_recover"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "manual-policy")

    assert {:ok, %{action: :paused_for_review, reason: reason}} =
             MirrorNeuron.recover_job(job_id)

    assert reason =~ "manual restart approval"
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert get_in(job, ["recovery", "can_resume"]) == true

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert get_in(completed, ["result", "output", "payload", "value"]) == 99

    RedisStore.delete_job(job_id)
  end

  test "local recovery skips jobs whose effective policy is cluster recovery" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cluster_policy_local_recovery_skip_test",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => config
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "cluster-policy")

    assert {:ok, %{action: :skipped, reason: "job is configured for cluster recovery"}} =
             MirrorNeuron.recover_job(job_id)

    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    refute Map.has_key?(job, "recovery_status")

    RedisStore.delete_job(job_id)
  end

  test "local recovery pauses unsafe in-progress steps for manual review" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "unsafe_recovery_review_test",
      "entrypoints" => ["writer"],
      "initial_inputs" => %{"writer" => [%{"value" => 99}]},
      "nodes" => [
        %{
          "node_id" => "writer",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => SafeRetryRunner,
            "side_effects" => "external",
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    restore_provenance = %{
      "source" => %{"job_id" => "backup-source-job", "run_id" => "source-run"},
      "target" => %{"run_id" => "restored-run"}
    }

    {:ok, job_id} =
      persist_recoverable_job(manifest, "unsafe-review", %{
        "restore_provenance" => restore_provenance
      })

    assert {:ok, %{action: :paused_for_review, reason: reason}} =
             MirrorNeuron.recover_job(job_id)

    assert reason =~ "do not declare retry safety"
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert get_in(job, ["recovery", "status"]) == "paused_for_review"
    assert job["restore_provenance"] == restore_provenance

    assert {:ok, jobs} = MirrorNeuron.list_jobs(summary: :basic, include_terminal: false)
    summary = Enum.find(jobs, &(&1["job_id"] == job_id))
    assert summary["recovery_status"] == "paused_for_review"
    assert summary["recovery_requires_review"] == true

    assert {:ok, details} = MirrorNeuron.job_details(job_id)
    assert get_in(details, ["summary", "recovery", "status"]) == "paused_for_review"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_paused_for_review"))

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert completed["attempt"] == 1
    assert get_in(completed, ["result", "output", "payload", "value"]) == 99

    RedisStore.delete_job(job_id)
  end

  test "local recovery pauses visibly when recovery manifest is missing" do
    job_id = "#{Runtime.generate_job_id("missing_manifest_recovery_test")}-missing-manifest"

    {:ok, _job} =
      RedisStore.persist_job(job_id, %{
        "job_id" => job_id,
        "graph_id" => "missing_manifest_recovery_test",
        "job_name" => "missing_manifest_recovery_test",
        "status" => "running",
        "submitted_at" => Runtime.timestamp(),
        "updated_at" => Runtime.timestamp(),
        "root_agent_ids" => ["worker"],
        "placement_policy" => "local",
        "recovery_policy" => "local_restart",
        "result" => nil,
        "topology" => %{
          "nodes" => [
            %{
              "node_id" => "worker",
              "agent_type" => "executor",
              "type" => "generic",
              "role" => "root_coordinator"
            }
          ],
          "edges" => []
        },
        "manifest_ref" => %{}
      })

    assert {:error, reason} = MirrorNeuron.recover_job(job_id)
    assert reason =~ "missing_recovery_manifest"
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert job["recovery_status"] == "paused_for_review"
    assert job["recovery_reason"] =~ "missing_recovery_manifest"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_paused_for_review"))

    RedisStore.delete_job(job_id)
  end

  test "can pause and cancel a single-run executor job before it completes" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cancel_once_test",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "cancel me"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => DelayedCompleteRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)

    wait_until(
      fn ->
        match?({:ok, %{"status" => "paused"}}, MirrorNeuron.inspect_job(job_id))
      end,
      2_000
    )

    assert {:ok, cancellation_status} = MirrorNeuron.cancel(job_id)
    assert cancellation_status in ["cancelled", "cancellation_pending"]

    if cancellation_status == "cancellation_pending" do
      assert :ok = MirrorNeuron.Runtime.CancellationReconciler.reconcile_now(job_id)
    end

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "cancelled"
    assert get_in(job, ["result", "reason"]) == "cancelled by durable cluster cancellation"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert_event_before(events, "job_pausing", "job_paused")
    assert_event_before(events, "job_paused", "job_cancelled")

    RedisStore.delete_job(job_id)
  end

  test "service jobs ignore task completion and keep the allocation running" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "service_completion_restart_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"work" => "stay up"}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => DelayedCompleteRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart", "job_type" => "service"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        {:ok, events} = MirrorNeuron.events(job_id)
        Enum.any?(events, &(&1["type"] == "service_agent_completed"))
      end,
      3_000
    )

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert job["job_type"] == "service"

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  test "cleanup all cancels live jobs before deleting their persisted state" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "safe_live_cleanup_test",
      "type" => "service",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "router",
          "role" => "root_coordinator"
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)
    assert job_runner_pid(job_id, false) != nil

    assert {:ok, result} = Runtime.cleanup_jobs(all: true)
    assert job_id in result.deleted_jobs

    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)
    assert Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) == []

    assert Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"}) ==
             []

    assert {:error, _reason} = RedisStore.fetch_job(job_id)
  end

  test "cleanup all preserves active state when the runtime cannot be stopped" do
    job_id = "unsafe-live-cleanup-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "unsafe_live_cleanup",
               "job_name" => "unsafe live cleanup",
               "status" => "running",
               "submitted_at" => Runtime.timestamp(),
               "updated_at" => Runtime.timestamp()
             })

    assert {:ok, result} = Runtime.cleanup_jobs(all: true)
    refute job_id in result.deleted_jobs
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(job_id)

    RedisStore.delete_job(job_id)
  end

  test "service jobs register and deregister declared service instances" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "service_registry_runtime_test",
      "type" => "service",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "services" => [
            %{
              "name" => "agent-api",
              "address" => "127.0.0.1",
              "port" => 18_080,
              "tags" => ["runtime-test"]
            }
          ]
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        {:ok, services} = ServiceRegistry.resolve("agent-api", job_id: job_id)
        Enum.any?(services, &(&1["agent_id"] == "worker" and &1["status"] == "passing"))
      end,
      2_000
    )

    assert {:ok, [service]} = ServiceRegistry.resolve("agent-api", job_id: job_id)
    assert service["node"] == to_string(Node.self())
    assert service["tags"] == ["runtime-test"]

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)

    wait_until(
      fn ->
        {:ok, services} = ServiceRegistry.list(job_id: job_id, passing_only: false)
        services == []
      end,
      2_000
    )

    RedisStore.delete_job(job_id)
  end

  test "sysbatch jobs complete after every eligible system target finishes once" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "sysbatch_completion_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"work" => "once per node"}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => DelayedCompleteRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart", "job_type" => "sysbatch"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)

    assert job["status"] == "completed"
    assert job["job_type"] == "sysbatch"
    assert get_in(job, ["scheduler", "system_count"]) == 1
    assert get_in(job, ["result", "completed_targets"]) == [to_string(Node.self())]
    assert map_size(get_in(job, ["result", "target_results"])) == 1

    RedisStore.delete_job(job_id)
  end

  test "cancel terminates busy agent workers instead of waiting for queued cancel casts" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cancel_busy_worker_test",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "cancel busy"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => LongSleepRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(fn -> event_count(job_id, "agent_message_received") >= 1 end, 2_000)

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)

    wait_until(fn -> agent_unregistered?(job_id, "root") end, 2_000)
    wait_until(fn -> agent_unregistered?(job_id, "worker") end, 2_000)
    wait_until(fn -> job_runner_unregistered?(job_id) end, 2_000)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "cancelled"

    RedisStore.delete_job(job_id)
  end

  test "can cancel a long-lived job and it disappears from the live list" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cancel_service_test",
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
          "config" => %{"complete_after" => 10, "terminal_sink" => true, "complete_run" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        {:ok, jobs} = MirrorNeuron.list_jobs(live_only: true, include_terminal: true)
        Enum.any?(jobs, &(&1["job_id"] == job_id))
      end,
      2_000
    )

    assert {:ok, cancellation_status} = MirrorNeuron.cancel(job_id)
    assert cancellation_status in ["cancelled", "cancellation_pending"]

    if cancellation_status == "cancellation_pending" do
      assert :ok = MirrorNeuron.Runtime.CancellationReconciler.reconcile_now(job_id)
    end

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "cancelled"

    wait_until(
      fn ->
        {:ok, jobs} = MirrorNeuron.list_jobs(live_only: true, include_terminal: true)
        Enum.all?(jobs, &(&1["job_id"] != job_id))
      end,
      2_000
    )

    RedisStore.delete_job(job_id)
  end

  test "accepts spec stream messages through the runtime and preserves stream metadata in events" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "stream_message_test",
      "nodes" => [
        %{"node_id" => "root", "agent_type" => "router", "role" => "root_coordinator"},
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

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    stream_message =
      Message.new(job_id, "external-client", "sink", "progress_chunk", "{\"checked\":10}\n",
        class: "stream",
        content_type: "application/x-ndjson",
        headers: %{"schema_ref" => "com.test.progress", "schema_version" => "1.0.0"},
        stream: %{"stream_id" => "stream-1", "seq" => 1, "open" => true, "close" => false}
      )

    assert {:ok, "delivered"} = MirrorNeuron.send_message(job_id, "sink", stream_message)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "last_message"]) == "{\"checked\":10}\n"

    assert {:ok, events} = MirrorNeuron.events(job_id)

    received =
      Enum.find(events, fn event ->
        event["type"] == "agent_message_received" and event["agent_id"] == "sink" and
          get_in(event, ["payload", "stream", "stream_id"]) == "stream-1"
      end)

    assert is_map(received), inspect(events, pretty: true)
    assert received["payload"]["stream"]["stream_id"] == "stream-1"
    assert received["payload"]["class"] == "stream"
    assert received["payload"]["content_type"] == "application/x-ndjson"

    RedisStore.delete_job(job_id)
  end

  test "runs the streaming peak demo manifest to completion" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "streaming_peak_runtime_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{
        "ingress" => [%{"scenario" => "runtime_stream_test"}]
      },
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "stream_start"}
        },
        %{
          "node_id" => "source",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => StreamProducerRunner,
            "output_message_type" => nil
          }
        },
        %{
          "node_id" => "detector",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => StreamDetectorRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "source", "message_type" => "stream_start"},
        %{"from_node" => "source", "to_node" => "detector", "message_type" => "telemetry_chunk"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "chunks_received"]) == 2
    assert get_in(job, ["result", "output", "peak_detected"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "stream_chunk_processed"))
    assert Enum.any?(events, &(&1["type"] == "agent_message_received"))

    RedisStore.delete_job(job_id)
  end

  test "live external input receives retry-later when stream agent is under backpressure" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "stream_live_backpressure_runtime_test",
      "type" => "service",
      "entrypoints" => ["slow_consumer"],
      "initial_inputs" => %{
        "slow_consumer" => [%{"value" => "warmup"}]
      },
      "nodes" => [
        %{
          "node_id" => "slow_consumer",
          "agent_type" => "executor",
          "type" => "stream",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => SlowBackpressureRunner,
            "output_message_type" => nil,
            "backpressure" => %{
              "max_queue_depth" => 4,
              "high_watermark" => 2,
              "low_watermark" => 1,
              "retry_after_ms" => 125
            }
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    results =
      1..16
      |> Task.async_stream(
        fn index ->
          MirrorNeuron.send_message(job_id, "slow_consumer", %{"value" => index})
        end,
        max_concurrency: 16,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.any?(results, &match?({:error, {:retry_later, _details}}, &1))
    assert Enum.any?(results, &match?({:ok, "delivered"}, &1))

    assert {:ok, pressure} = MirrorNeuron.pressure(job_id)
    assert is_map(pressure["agents"]["slow_consumer"])

    wait_until(
      fn ->
        {:ok, events} = MirrorNeuron.events(job_id)

        Enum.any?(events, &(&1["type"] == "external_input_rejected")) and
          Enum.any?(events, &(&1["type"] == "backpressure_state"))
      end,
      2_000
    )

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  test "reports executor pool capacity in cluster inspection" do
    assert {:ok, nodes} = {:ok, MirrorNeuron.inspect_nodes()}

    assert Enum.any?(nodes, fn node ->
             node["self?"] || node[:self?]
           end)

    local_node =
      Enum.find(nodes, fn node ->
        (node["self?"] || node[:self?]) == true
      end)

    pools = local_node["executor_pools"] || local_node[:executor_pools]
    default_pool = pools["default"] || pools[:default]

    assert is_map(default_pool)
    assert (default_pool["capacity"] || default_pool[:capacity]) >= 1
  end

  test "runs a dependency-heavy sandbox worker only when its execution profile is advertised" do
    profile = "opencv-video-guardian-runtime-#{System.unique_integer([:positive])}"
    restore_profiles = put_test_profiles(%{profile => profile_config("registry.local/video:ok")})

    RedisStore.persist_node_state(to_string(Node.self()), %{
      "status" => "healthy",
      "profiles" => [profile],
      "profile_health" => %{profile => %{"status" => "healthy"}},
      "gpu" => false,
      "capabilities" => ["video-codec:h264"]
    })

    manifest = profiled_executor_manifest("profiled_runtime_success", profile)

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 5_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "profile"]) == profile
    assert get_in(job, ["result", "output", "image"]) == "registry.local/video:ok"

    assert {:ok, agent} = RedisStore.fetch_agent(job_id, "video_guardian")
    assert get_in(agent, ["metadata", "execution_profile"]) == profile
    assert agent["assigned_node"] == to_string(Node.self())

    RedisStore.delete_job(job_id)
    restore_profiles.()
  end

  test "pauses profiled work for review when no runtime node advertises the profile" do
    profile = "missing-opencv-profile-#{System.unique_integer([:positive])}"

    restore_profiles =
      put_test_profiles(%{profile => profile_config("registry.local/video:missing")})

    RedisStore.persist_node_state(to_string(Node.self()), %{
      "status" => "healthy",
      "profiles" => [],
      "profile_health" => %{},
      "gpu" => false,
      "capabilities" => []
    })

    manifest = profiled_executor_manifest("profiled_runtime_pauses", profile)

    assert {:ok, job_id} = run_manifest(manifest)

    wait_until(fn ->
      match?({:ok, %{"status" => "paused"}}, MirrorNeuron.inspect_job(job_id))
    end)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_status"] == "paused_for_review"
    assert job["recovery_requires_review"] == true
    assert job["recovery_reason"] =~ "execution profile #{profile} has no eligible runtime nodes"

    assert {:ok, events} = MirrorNeuron.events(job_id)

    assert Enum.any?(events, fn event ->
             event["type"] == "job_paused_for_manual_restart" and
               event["execution_profile"] == profile
           end)

    RedisStore.delete_job(job_id)
    restore_profiles.()
  end

  test "waits for all agents to register before seeding entrypoints" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "fanout_registration_test",
      "entrypoints" => ["dispatcher"],
      "initial_inputs" => %{
        "dispatcher" => [%{"text" => "fan out"}]
      },
      "nodes" =>
        [
          %{
            "node_id" => "dispatcher",
            "agent_type" => "router",
            "role" => "root_coordinator",
            "config" => %{"emit_type" => "fanout"}
          },
          %{
            "node_id" => "sink",
            "agent_type" => "aggregator",
            "config" => %{"complete_after" => 4, "terminal_sink" => true, "complete_run" => true}
          }
        ] ++
          Enum.map(1..4, fn index ->
            %{"node_id" => "worker_#{index}", "agent_type" => "router"}
          end),
      "edges" =>
        Enum.flat_map(1..4, fn index ->
          [
            %{
              "from_node" => "dispatcher",
              "to_node" => "worker_#{index}",
              "message_type" => "fanout"
            },
            %{
              "from_node" => "worker_#{index}",
              "to_node" => "sink",
              "message_type" => "fanout"
            }
          ]
        end),
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job["status"] == "completed"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    refute Enum.any?(events, &(&1["type"] == "dead_letter"))

    RedisStore.delete_job(job_id)
  end

  defp put_test_profiles(profiles) do
    previous = Application.get_env(:mirror_neuron, :execution_profiles)
    Application.put_env(:mirror_neuron, :execution_profiles, profiles)

    fn ->
      if previous == nil do
        Application.delete_env(:mirror_neuron, :execution_profiles)
      else
        Application.put_env(:mirror_neuron, :execution_profiles, previous)
      end
    end
  end

  defp profile_config(image) do
    %{
      "image" => image,
      "pool" => "default",
      "pool_slots" => 1,
      "required_capabilities" => ["video-codec:h264"],
      "reuse_shared_sandbox" => true,
      "persistent_workspace" => true
    }
  end

  defp profiled_executor_manifest(graph_id, profile) do
    %{
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "entrypoints" => ["video_guardian"],
      "nodes" => [
        %{
          "node_id" => "video_guardian",
          "agent_type" => "sandbox_worker",
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

  test "keeps a terminal report durable while the coordinator is gone" do
    job_id = "worker_fallback_test-#{System.unique_integer([:positive])}"

    node = %{
      node_id: "sink",
      agent_type: "aggregator",
      role: "sink",
      config: %{"complete_on_message" => true, "terminal_sink" => true, "complete_run" => true}
    }

    coordinator =
      spawn(fn ->
        receive do
        after
          1 -> :ok
        end
      end)

    Process.exit(coordinator, :kill)

    runtime_context = %{
      graph_id: "worker_fallback_test",
      job_name: "worker_fallback_test",
      entrypoints: ["sink"],
      placement_policy: "local",
      recovery_policy: "local_restart",
      submitted_at:
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      manifest_version: "1.0"
    }

    assert {:ok, pid} =
             AgentWorker.start_link({job_id, node, [], [], coordinator, runtime_context})

    message =
      Message.new(job_id, "external", "sink", "manual_result", %{"value" => "done"},
        correlation_id: "test-correlation"
      )

    GenServer.cast(pid, {:deliver, message})

    wait_until(fn ->
      RedisStore.delivery_pending_count(job_id, Delivery.coordinator_agent_id()) == {:ok, 1}
    end)

    assert {:error, _reason} = MirrorNeuron.inspect_job(job_id)

    consumer = Delivery.consumer_id(job_id, Delivery.coordinator_agent_id())

    assert {:ok, [delivery]} =
             Delivery.read(job_id, Delivery.coordinator_agent_id(), consumer)

    report = Message.body(delivery.message)
    assert report["kind"] == "agent_completed_run"
    assert report["agent_id"] == "sink"
    assert get_in(report, ["result", "count"]) == 1
    assert get_in(report, ["result", "last_message", "value"]) == "done"

    assert :ok =
             Delivery.ack(
               job_id,
               Delivery.coordinator_agent_id(),
               consumer,
               delivery
             )

    GenServer.stop(pid)
    RedisStore.delete_job(job_id)
  end

  test "workflow coordinator reports remain idempotent across delivery retries" do
    job_id = "workflow_report_retry_test-#{System.unique_integer([:positive])}"
    report_id = "stable-workflow-received-report"

    first_attempt =
      Message.new(job_id, "external", "retrying_worker", "retryable_work", %{"value" => 1},
        correlation_id: "retry-correlation",
        headers: %{
          "mn.workflow.run_id" => "workflow-run",
          "mn.workflow.step_id" => "retry_step",
          "mn.workflow.attempt" => 1,
          "mn.workflow.attempt_id" => "retry_step:attempt:1",
          "mn.workflow.idempotency_key" => "workflow-run:retry_step:1"
        }
      )
      |> put_in(["envelope", "attempt"], 1)

    second_attempt = put_in(first_attempt, ["envelope", "attempt"], 2)

    report_body = fn message ->
      %{
        "kind" => "workflow_message_received",
        "agent_id" => "retrying_worker",
        "message" => Delivery.stable_workflow_message(message)
      }
    end

    assert :ok =
             Delivery.report(
               job_id,
               "retrying_worker",
               report_id,
               report_body.(first_attempt)
             )

    assert :ok =
             Delivery.report(
               job_id,
               "retrying_worker",
               report_id,
               report_body.(second_attempt)
             )

    assert RedisStore.delivery_pending_count(job_id, Delivery.coordinator_agent_id()) ==
             {:ok, 1}

    consumer = Delivery.consumer_id(job_id, Delivery.coordinator_agent_id())

    assert {:ok, [report]} =
             Delivery.read(job_id, Delivery.coordinator_agent_id(), consumer)

    body = Message.body(report.message)
    assert body["kind"] == "workflow_message_received"
    refute Map.has_key?(get_in(body, ["message", "envelope"]), "attempt")

    assert :ok =
             Delivery.ack(
               job_id,
               Delivery.coordinator_agent_id(),
               consumer,
               report
             )

    RedisStore.delete_job(job_id)
  end

  test "heartbeats and checkpoint actions never serialize agent memory" do
    job_id = "checkpoint_perf_test-#{System.unique_integer([:positive])}"
    parent = self()

    coordinator =
      spawn(fn ->
        checkpoint_proxy(parent, job_id)
      end)

    node = %{
      node_id: "checkpoint_agent",
      agent_type: "module",
      role: "root",
      config: %{"module" => ExplicitCheckpointAgent}
    }

    runtime_context = %{
      graph_id: "checkpoint_perf_test",
      job_name: "checkpoint_perf_test",
      entrypoints: ["checkpoint_agent"],
      placement_policy: "local",
      recovery_policy: "local_restart",
      submitted_at:
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      manifest_version: "1.0"
    }

    assert {:ok, pid} =
             AgentWorker.start_link({job_id, node, [], [], coordinator, runtime_context})

    assert {:ok, observation} = RedisStore.fetch_agent(job_id, "checkpoint_agent")
    assert observation["agent_id"] == "checkpoint_agent"
    refute Map.has_key?(observation, "current_state")
    refute Map.has_key?(observation, "inflight_message")
    refute Map.has_key?(observation, "pending_messages")
    refute Map.has_key?(observation["metadata"], "recovery_state")

    refute_receive {:checkpoint_persisted, _snapshot}, 200

    message =
      Message.new(job_id, "external", "checkpoint_agent", "checkpoint", %{"value" => "save"},
        correlation_id: "checkpoint-correlation"
      )

    GenServer.cast(pid, {:deliver, message})

    assert_receive {:checkpoint_ignored, %{"metadata" => %{"explicit_checkpoint" => true}}},
                   1_000

    assert {:ok, observation} = RedisStore.fetch_agent(job_id, "checkpoint_agent")
    refute Map.has_key?(observation["metadata"], "explicit_checkpoint")
    refute Map.has_key?(observation["metadata"], "recovery_state")

    refute_receive {:checkpoint_ignored, _snapshot}, 200

    GenServer.stop(pid)
    Process.exit(coordinator, :kill)
    RedisStore.delete_job(job_id)
  end

  test "agent startup and heartbeats never create disk checkpoints" do
    job_id = "agent-startup-no-checkpoint-#{System.unique_integer([:positive])}"
    agent_id = "startup_agent"
    checkpoint_root = Path.join(System.tmp_dir!(), "#{job_id}-checkpoints")
    previous_root = System.get_env("MN_CHECKPOINT_ROOT")
    System.put_env("MN_CHECKPOINT_ROOT", checkpoint_root)

    on_exit(fn ->
      restore_system_env("MN_CHECKPOINT_ROOT", previous_root)
      File.rm_rf!(checkpoint_root)
    end)

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "agent-startup-no-checkpoint",
               "status" => "pending",
               "updated_at" => Runtime.timestamp()
             })

    parent = self()

    node = %{
      node_id: agent_id,
      agent_type: "module",
      role: "root",
      config: %{"module" => ExplicitCheckpointAgent}
    }

    runtime_context = %{
      graph_id: "agent-startup-no-checkpoint",
      job_name: "agent-startup-no-checkpoint",
      entrypoints: [agent_id],
      placement_policy: "local",
      recovery_policy: "local_restart",
      submitted_at: Runtime.timestamp(),
      manifest_version: "1.0"
    }

    worker =
      Task.async(fn ->
        AgentWorker.start_link({job_id, node, [], [], parent, runtime_context})
      end)

    assert {:ok, {:ok, pid}} = Task.yield(worker, 1_000)

    send(pid, :heartbeat)
    assert %{"agent_id" => ^agent_id} = GenServer.call(pid, :pressure_snapshot, 1_000)

    assert {:ok, %{"agent_id" => ^agent_id}} = RedisStore.fetch_agent(job_id, agent_id)
    refute File.exists?(checkpoint_root)

    GenServer.stop(pid)
    RedisStore.delete_job(job_id)
  end

  test "restarts a missing agent and replays its inflight message" do
    {:ok, counter_pid} = start_supervised(CrashOnceCounter)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "agent_recovery_test",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "recover"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => CrashOnceRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "max_agent_restart_attempts" => 2
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(fn -> worker_pid(job_id) end, 2_000)
    wait_until(fn -> attempt_started?(job_id, 1) end, 2_000)

    assert {:ok, before_restart} = MirrorNeuron.inspect_job(job_id)

    [{pid, _}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

    Process.exit(pid, :kill)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 8_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "recovered"]) == true
    assert get_in(job, ["result", "output", "invocation"]) == 2
    assert job["attempt"] == before_restart["attempt"] + 1
    assert job["recovery_mode"] == "clean_restart"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_clean_restart_scheduled"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" && &1["attempt"] == 2))

    GenServer.stop(counter_pid)
    RedisStore.delete_job(job_id)
  end

  test "batch job fails after restart policy attempts are exhausted" do
    # This test deliberately kills two workers. Keep the health checker from
    # racing those explicit restart transitions under a loaded CI runner.
    previous_health_interval = Application.get_env(:mirror_neuron, :job_health_check_interval_ms)
    Application.put_env(:mirror_neuron, :job_health_check_interval_ms, 1_000)

    on_exit(fn ->
      restore_application_env(:job_health_check_interval_ms, previous_health_interval)
    end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "batch_restart_policy_exhaustion",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "fail after retry"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => LongSleepRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => 1,
          "interval_ms" => 60_000,
          "delay_ms" => 1,
          "delay_function" => "constant",
          "max_delay_ms" => 1,
          "mode" => "fail"
        },
        "reschedule" => %{"attempts" => 0}
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(fn -> worker_pid(job_id) end, 3_000)
    wait_until(fn -> attempt_started?(job_id, 1) end, 2_000)

    [{first_pid, _}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

    Process.exit(first_pid, :kill)

    wait_until(
      fn ->
        with {:ok, restarted} <- MirrorNeuron.inspect_job(job_id) do
          restarted["attempt"] == 2 and
            replacement_worker_pid?(job_id, first_pid) and
            attempt_started?(job_id, 2)
        else
          _ -> false
        end
      end,
      12_000
    )

    [{second_pid, _}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

    Process.exit(second_pid, :kill)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 12_000)
    assert job["status"] == "failed"
    assert get_in(job, ["restart_budget", "attempts"]) == 1

    RedisStore.delete_job(job_id)
  end

  test "long-lived jobs do not fail when recovery attempts exceed the normal cap" do
    :ok = CrashTwiceCounter.init()

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "service_agent_recovery_test",
      "type" => "service",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "keep recovering"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => CrashTwiceRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => 1,
          "interval_ms" => 100,
          "delay_ms" => 1,
          "delay_function" => "constant",
          "max_delay_ms" => 1,
          "mode" => "delay"
        }
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)

    for invocation <- 1..2 do
      wait_until(fn -> CrashTwiceCounter.invocations() == invocation end, 3_000)

      wait_until(
        fn ->
          match?(
            [{_pid, _}],
            Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})
          )
        end,
        2_000
      )

      [{pid, _}] =
        Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

      Process.exit(pid, :kill)

      wait_until(
        fn ->
          with {:ok, attempt_job} <- MirrorNeuron.inspect_job(job_id) do
            attempt_job["status"] == "running" and
              attempt_job["attempt"] >= invocation + 1 and
              event_count(job_id, "job_attempt_started") >= invocation + 1
          else
            _ -> false
          end
        end,
        3_000
      )
    end

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.count(events, &(&1["type"] == "job_attempt_started")) >= 3
    refute Enum.any?(events, &(&1["type"] == "agent_recovered"))

    wait_until(
      fn ->
        {:ok, events} = MirrorNeuron.events(job_id)
        Enum.any?(events, &(&1["type"] == "service_agent_completed"))
      end,
      12_000
    )

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert job["job_type"] == "service"
    assert job["attempt"] >= 3

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  defp running_status?(job_id) do
    case MirrorNeuron.inspect_job(job_id) do
      {:ok, %{"status" => "running"}} -> true
      _ -> false
    end
  end

  defp cleanup_job_on_exit(job_id) do
    on_exit(fn -> cleanup_runtime_job(job_id) end)
    :ok
  end

  defp cleanup_runtime_job(job_id) do
    _ = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  defp pause_resume_dag_manifest(graph_id) do
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

  defp workflow_test_step(id, title, requires, provides) do
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

  defp assert_runtime_workflow_manifest(job_id) do
    assert {:ok, job} = RedisStore.fetch_job(job_id)
    assert get_in(job, ["manifest", "apiVersion"]) == "mn.workflow/v1"
    assert get_in(job, ["manifest", "kind"]) == "Workflow"
    assert get_in(job, ["manifest", "contract", "outputs"]) == [%{"id" => "review_packet"}]
    assert get_in(job, ["manifest", "flow", "graph", "schema"]) == "mn.workflow.problem_graph/v1"
    assert get_in(job, ["manifest", "flow", "graph", "dynamic", "enabled"]) == false

    assert get_in(job, ["manifest", "flow", "graph", "edges"]) |> Enum.map(& &1["id"]) == [
             "edge-intake-review",
             "edge-review-write"
           ]

    assert get_in(job, ["manifest", "flow", "steps"])
           |> Enum.find(&(&1["id"] == "write_packet"))
           |> get_in(["join", "mode"]) == "all_required"

    assert get_in(job, ["manifest", "runtime", "bindings", "manual_review", "workers"])
           |> Enum.map(& &1["id"]) == ["router_worker", "sink_worker"]
  end

  defp worker_pid(job_id) do
    match?(
      [{_pid, _}],
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})
    )
  end

  defp replacement_worker_pid?(job_id, previous_pid) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"}) do
      [{pid, _}] when pid != previous_pid -> Process.alive?(pid)
      _ -> false
    end
  end

  defp attempt_started?(job_id, attempt) do
    case MirrorNeuron.events(job_id) do
      {:ok, events} ->
        Enum.any?(events, fn event ->
          event["type"] == "job_attempt_started" and event["attempt"] == attempt
        end)

      _ ->
        false
    end
  end

  defp job_coordinator_registered?(job_id) do
    match?(
      [{_pid, _}],
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id})
    )
  end

  defp agent_registered?(job_id, agent_id) do
    match?(
      [{_pid, _}],
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id})
    )
  end

  defp job_coordinator_pid(job_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
      [{pid, _meta}] -> pid
      _ -> flunk("job coordinator was not registered for #{job_id}")
    end
  end

  defp job_runner_pid(job_id, fail? \\ true) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) do
      [{pid, _meta}] ->
        pid

      _ when fail? ->
        flunk("job runner was not registered for #{job_id}")

      _ ->
        nil
    end
  end

  defp agent_paused?(job_id, agent_id) do
    case agent_snapshot(job_id, agent_id) do
      %{"metadata" => %{"paused" => true}} -> true
      _ -> false
    end
  end

  defp agent_pending_count(job_id, agent_id) do
    case agent_snapshot(job_id, agent_id) do
      %{"metadata" => %{"pending_message_count" => count}} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp agent_snapshot(job_id, agent_id) do
    case MirrorNeuron.inspect_agents(job_id) do
      {:ok, agents} -> Enum.find(agents, &(&1["agent_id"] == agent_id))
      _ -> nil
    end
  end

  defp deployment_service_manifest(deployment_key, version) do
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

  defp persist_recoverable_job(manifest, suffix, extra_attrs \\ %{}) do
    with {:ok, bundle} <- MirrorNeuron.JobBundle.load(flow_manifest(manifest)) do
      job_id = "#{Runtime.generate_job_id(bundle.manifest.graph_id)}-#{suffix}"
      manifest_map = MirrorNeuron.Manifest.to_map(bundle.manifest)

      {:ok, _job} =
        RedisStore.persist_job(
          job_id,
          Map.merge(
            %{
              "job_id" => job_id,
              "graph_id" => bundle.manifest.graph_id,
              "job_name" => bundle.manifest.job_name,
              "type" => bundle.manifest.type,
              "required_context_engine" => bundle.manifest.required_context_engine,
              "status" => "running",
              "submitted_at" => Runtime.timestamp(),
              "updated_at" => Runtime.timestamp(),
              "root_agent_ids" => bundle.manifest.entrypoints,
              "placement_policy" =>
                Map.get(bundle.manifest.policies, "placement_policy", "local"),
              "recovery_policy" =>
                Map.get(bundle.manifest.policies, "recovery_mode", "local_restart"),
              "result" => nil,
              "topology" => MirrorNeuron.Manifest.topology(bundle.manifest),
              "manifest" => manifest_map,
              "manifest_ref" => %{}
            },
            extra_attrs
          )
        )

      {:ok, job_id}
    end
  end

  defp run_manifest(input, opts \\ []) do
    MirrorNeuron.run_manifest(flow_manifest(input), opts)
  end

  defp bundle_echo_output(job) do
    candidates = [
      get_in(job, ["result", "output"]),
      get_in(job, ["result", "output", "output"]),
      get_in(job, ["result", "output", "complete_run"]),
      get_in(job, ["result", "complete_run"]),
      decode_bundle_echo_stdout(get_in(job, ["result", "output", "sandbox", "stdout"])),
      decode_bundle_echo_stdout(get_in(job, ["result", "sandbox", "stdout"]))
    ]

    case Enum.find(candidates, &(is_map(&1) and is_binary(Map.get(&1, "bundle_root")))) do
      nil -> flunk("bundle echo output missing from job result: #{inspect(job["result"])}")
      output -> output
    end
  end

  defp decode_bundle_echo_stdout(stdout) when is_binary(stdout) do
    case Jason.decode(stdout) do
      {:ok, %{"complete_run" => output}} when is_map(output) -> output
      {:ok, output} when is_map(output) -> output
      _ -> nil
    end
  end

  defp decode_bundle_echo_stdout(_stdout), do: nil

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp deploy_manifest(input, opts) do
    MirrorNeuron.deploy_manifest(flow_manifest(input), opts)
  end

  defp update_deployment(deployment_key, input, opts \\ []) do
    MirrorNeuron.update_deployment(deployment_key, flow_manifest(input), opts)
  end

  defp flow_manifest(%{} = manifest) do
    {nodes, manifest} = Map.pop(manifest, "nodes")
    {edges, manifest} = Map.pop(manifest, "edges")

    flow =
      manifest
      |> Map.get("flow", %{})
      |> maybe_put_topology("nodes", nodes)
      |> maybe_put_topology("edges", edges)

    Map.put(manifest, "flow", flow)
  end

  defp flow_manifest(input), do: input

  defp maybe_put_topology(flow, _key, nil), do: flow
  defp maybe_put_topology(flow, key, value), do: Map.put(flow, key, value)

  defp redis_key(parts) do
    namespace = MirrorNeuron.Config.string("MN_REDIS_NAMESPACE", :redis_namespace)
    Enum.join([namespace | parts], ":")
  end

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end

  defp cleanup_runtime_namespace do
    case RedisStore.list_jobs() do
      {:ok, jobs} ->
        Enum.each(jobs, fn job ->
          if job_id = job["job_id"], do: cleanup_runtime_job(job_id)
        end)

      _ ->
        :ok
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_application_env(key, value), do: Application.put_env(:mirror_neuron, key, value)

  defp agent_unregistered?(job_id, agent_id) do
    Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) == []
  end

  defp job_runner_unregistered?(job_id) do
    Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) == []
  end

  defp checkpoint_proxy(parent, job_id) do
    receive do
      {:agent_checkpoint, agent_id, snapshot} ->
        _ = {job_id, agent_id}
        send(parent, {:checkpoint_ignored, snapshot})
        checkpoint_proxy(parent, job_id)

      _message ->
        checkpoint_proxy(parent, job_id)
    end
  end

  defp send_counter_messages(job_id, range) do
    Enum.each(range, fn id ->
      result =
        MirrorNeuron.send_message(job_id, "counter", %{
          "type" => "counter_step",
          "payload" => %{"id" => id}
        })

      assert result == {:ok, "delivered"},
             "counter input #{id} failed with #{inspect(result)}; job=#{inspect(MirrorNeuron.inspect_job(job_id))}"
    end)
  end

  defp event_count(job_id, event_type) do
    case MirrorNeuron.events(job_id) do
      {:ok, events} -> Enum.count(events, &(&1["type"] == event_type))
      _ -> 0
    end
  end

  defp assert_event_before(events, earlier_type, later_type) do
    earlier_index = event_index(events, earlier_type)
    later_index = event_index(events, later_type)

    assert earlier_index,
           "expected #{earlier_type} event in #{inspect(Enum.map(events, & &1["type"]))}"

    assert later_index,
           "expected #{later_type} event in #{inspect(Enum.map(events, & &1["type"]))}"

    assert earlier_index < later_index,
           "expected #{earlier_type} before #{later_type}, got #{inspect(Enum.map(events, & &1["type"]))}"
  end

  defp event_index(events, event_type) do
    Enum.find_index(events, &(&1["type"] == event_type))
  end

  defp wait_until(fun, timeout \\ 1_000) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_until(fun, started_at, timeout)
  end

  defp do_wait_until(fun, started_at, timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) - started_at > timeout do
        flunk("condition was not met within #{timeout}ms")
      else
        Process.sleep(20)
        do_wait_until(fun, started_at, timeout)
      end
    end
  end
end
