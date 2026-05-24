defmodule MirrorNeuron.RuntimeTest do
  use ExUnit.Case

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AgentWorker
  alias MirrorNeuron.ServiceRegistry

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
             "complete_job" => completion
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
                 "complete_job" => %{
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
                 "complete_job" => %{
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
         "stdout" => Jason.encode!(%{"complete_job" => %{"done" => true}}),
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
         "stdout" => Jason.encode!(%{"complete_job" => %{"done" => true}}),
         "stderr" => "",
         "logs" => ""
       }}
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
             "complete_job" => %{
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

  defmodule ProfiledCompleteRunner do
    def run(_payload, config, _opts) do
      {:ok,
       %{
         "sandbox_name" => "profiled-complete",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "complete_job" => %{
               "profile" => Map.get(config, "execution_profile"),
               "image" => Map.get(config, "from")
             }
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
             "complete_job" => %{
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
          seen_ids =
            if is_nil(message_id), do: state.seen_ids, else: state.seen_ids ++ [message_id]

          next_state = %{state | count: state.count + 1, seen_ids: seen_ids}

          actions = [{:event, :counter_step_completed, %{"count" => next_state.count}}]

          actions =
            if next_state.count >= next_state.target do
              actions ++
                [
                  {:complete_job,
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

    Application.put_env(:mirror_neuron, :job_health_check_interval_ms, 100)
    Application.put_env(:mirror_neuron, :agent_heartbeat_interval_ms, 100)
    System.put_env("MN_RESOURCE_ADMISSION_ENABLED", "false")

    on_exit(fn ->
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "router", "message_type" => "research_request"},
        %{"from_node" => "router", "to_node" => "sink", "message_type" => "research_request"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 2_000)
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
             MirrorNeuron.run_manifest(manifest,
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "sink", "message_type" => "done"}
      ]
    }

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 2_000)
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "sink", "message_type" => "done"}
      ],
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 2_000)
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
          "config" => %{"complete_on_message" => true}
        },
        %{
          "node_id" => "human_review",
          "agent_type" => "aggregator",
          "config" => %{"complete_on_message" => true}
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

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 2_000)
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

  test "queues messages while paused and completes after resume" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "pause_resume_test",
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_paused?(job_id, "sink") end)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved while paused"}
             })

    wait_until(fn -> agent_pending_count(job_id, "sink") == 1 end)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "completed"

    RedisStore.delete_job(job_id)
  end

  test "resume is idempotent for an already running job" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "resume_running_idempotent_test",
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, %{"status" => "running"}} = MirrorNeuron.inspect_job(job_id)

    RedisStore.delete_job(job_id)
  end

  test "recovers a paused job after coordinator restart and completes after resume" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "pause_resume_recovery_test",
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_paused?(job_id, "sink") end)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved across restart"}
             })

    wait_until(fn -> agent_pending_count(job_id, "sink") == 1 end)

    old_coordinator = job_coordinator_pid(job_id)
    Process.exit(old_coordinator, :kill)

    wait_until(
      fn ->
        case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
          [{pid, _meta}] -> pid != old_coordinator
          _ -> false
        end
      end,
      3_000
    )

    wait_until(fn -> agent_paused?(job_id, "sink") end, 3_000)
    assert {:ok, %{"status" => "paused"}} = MirrorNeuron.inspect_job(job_id)
    assert agent_pending_count(job_id, "sink") == 1

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "last_message", "text"]) == "approved across restart"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_recovery_scheduled"))
    assert Enum.any?(events, &(&1["type"] == "job_recovered"))

    RedisStore.delete_job(job_id)
  end

  test "manual resume restarts a paused orphaned job after local process loss" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "manual_resume_orphan_test",
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_paused?(job_id, "sink") end)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "manual resume after reboot"}
             })

    wait_until(fn -> agent_pending_count(job_id, "sink") == 1 end)

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"

    assert get_in(job, ["result", "output", "last_message", "text"]) ==
             "manual resume after reboot"

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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, %{"status" => "running"}} = MirrorNeuron.inspect_job(job_id)
    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    wait_until(fn -> running_status?(job_id) and job_runner_pid(job_id, false) != nil end, 3_000)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_paused_for_manual_resume"))
    assert Enum.any?(events, &(&1["type"] == "job_recovered"))

    RedisStore.delete_job(job_id)
  end

  test "long-running workflow resumes from checkpoint without repeating completed steps" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "long_running_checkpoint_resume_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{"module" => DurableCounterAgent, "target" => 12}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    send_counter_messages(job_id, 1..5)

    wait_until(
      fn ->
        agent_current_count(job_id, "counter") == 5
      end,
      2_000
    )

    old_coordinator = job_coordinator_pid(job_id)
    Process.exit(old_coordinator, :kill)

    wait_until(
      fn ->
        running_status?(job_id) and
          case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
            [{pid, _meta}] -> pid != old_coordinator
            _ -> false
          end
      end,
      3_000
    )

    wait_until(fn -> agent_current_count(job_id, "counter") == 5 end, 3_000)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "counter", %{
               "type" => "counter_step",
               "payload" => %{"id" => 5}
             })

    send_counter_messages(job_id, 6..12)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "count"]) == 12
    assert get_in(job, ["result", "output", "seen_ids"]) == Enum.to_list(1..12)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_recovered"))
    assert Enum.any?(events, &(&1["type"] == "counter_duplicate_ignored"))
    assert Enum.count(events, &(&1["type"] == "counter_step_completed")) == 12

    RedisStore.delete_job(job_id)
  end

  test "reboot-like startup scan resumes a safe workflow from its durable checkpoint" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_reboot_resume_test",
      "nodes" => [
        %{
          "node_id" => "counter",
          "agent_type" => "module",
          "role" => "root_coordinator",
          "config" => %{"module" => DurableCounterAgent, "target" => 8}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    send_counter_messages(job_id, 1..5)
    wait_until(fn -> agent_current_count(job_id, "counter") == 5 end, 2_000)

    runner = job_runner_pid(job_id)
    :ok = Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, runner)
    wait_until(fn -> job_runner_pid(job_id, false) == nil end, 2_000)

    assert {:ok, result} = MirrorNeuron.recover_unfinished_jobs(reason: "test_startup_scan")
    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    wait_until(fn -> running_status?(job_id) end, 3_000)
    wait_until(fn -> agent_current_count(job_id, "counter") == 5 end, 3_000)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "counter", %{
               "type" => "counter_step",
               "payload" => %{"id" => 5}
             })

    send_counter_messages(job_id, 6..8)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "count"]) == 8
    assert get_in(job, ["result", "output", "seen_ids"]) == Enum.to_list(1..8)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.count(events, &(&1["type"] == "counter_step_completed")) == 8

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
          "config" => %{"module" => DurableCounterAgent, "target" => 3}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    send_counter_messages(job_id, 1..1)
    wait_until(fn -> agent_current_count(job_id, "counter") == 1 end, 2_000)

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

    wait_until(fn -> agent_current_count(job_id, "counter") == 1 end, 3_000)
    send_counter_messages(job_id, 2..3)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "count"]) == 3
    assert get_in(job, ["result", "output", "seen_ids"]) == Enum.to_list(1..3)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.count(events, &(&1["type"] == "counter_step_completed")) == 3

    RedisStore.delete_job(job_id)
  end

  test "startup scan repairs a missing agent index before recovery" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "local_reboot_agent_index_repair_test",
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
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "agent-index-repair")

    RedisStore.persist_agent(job_id, "worker", %{
      "agent_id" => "worker",
      "node_id" => "worker",
      "agent_type" => "executor",
      "current_state" => %{"runs" => 0},
      "mailbox_depth" => 0,
      "processed_messages" => 0,
      "inflight_message" => %{
        "id" => "agent-index-message-1",
        "job_id" => job_id,
        "to" => "worker",
        "type" => "retry_safe_work",
        "payload" => %{"value" => 77}
      },
      "pending_messages" => [],
      "last_heartbeat_at" => Runtime.timestamp(),
      "parent_job_id" => job_id,
      "metadata" => %{
        "paused" => false,
        "recovery_state" =>
          encoded_checkpoint(%{
            config: config,
            runs: 0,
            agent_state: %{},
            last_output_payload: nil,
            last_result: nil,
            last_error: nil
          })
      }
    })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SREM",
               redis_key(["job", job_id, "agents"]),
               "worker"
             ])

    assert {:ok, result} = MirrorNeuron.recover_unfinished_jobs(reason: "test_agent_index_repair")
    recovered = Enum.find(result.jobs, &(&1.job_id == job_id))
    assert recovered.action in [:started, :already_running]

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "payload", "value"]) == 77
    assert get_in(job, ["result", "output", "retried"]) == true

    assert {:ok, agents} = MirrorNeuron.inspect_agents(job_id)
    assert Enum.any?(agents, &(&1["agent_id"] == "worker"))

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_auto_resumed"))
    assert Enum.any?(events, &(&1["type"] == "sandbox_job_completed"))

    RedisStore.delete_job(job_id)
  end

  test "local recovery retries an in-progress step when it is explicitly safe" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "safe_inflight_retry_test",
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
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "safe-retry")

    RedisStore.persist_agent(job_id, "worker", %{
      "agent_id" => "worker",
      "node_id" => "worker",
      "agent_type" => "executor",
      "current_state" => %{"runs" => 0},
      "mailbox_depth" => 0,
      "processed_messages" => 0,
      "inflight_message" => %{
        "id" => "safe-message-1",
        "job_id" => job_id,
        "to" => "worker",
        "type" => "retry_safe_work",
        "payload" => %{"value" => 42}
      },
      "pending_messages" => [],
      "last_heartbeat_at" => Runtime.timestamp(),
      "parent_job_id" => job_id,
      "metadata" => %{
        "paused" => false,
        "recovery_state" =>
          encoded_checkpoint(%{
            config: config,
            runs: 0,
            agent_state: %{},
            last_output_payload: nil,
            last_result: nil,
            last_error: nil
          })
      }
    })

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
          "config" => %{"complete_after" => 1}
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

    RedisStore.persist_agent(job_id, "worker", %{
      "agent_id" => "worker",
      "node_id" => "worker",
      "agent_type" => "executor",
      "current_state" => %{"runs" => 0},
      "mailbox_depth" => 0,
      "processed_messages" => 0,
      "inflight_message" => %{
        "id" => "manual-policy-message-1",
        "job_id" => job_id,
        "to" => "worker",
        "type" => "retry_safe_work",
        "payload" => %{"value" => 99}
      },
      "pending_messages" => [],
      "last_heartbeat_at" => Runtime.timestamp(),
      "parent_job_id" => job_id,
      "metadata" => %{
        "paused" => false,
        "recovery_state" =>
          encoded_checkpoint(%{
            config: config,
            runs: 0,
            agent_state: %{},
            last_output_payload: nil,
            last_result: nil,
            last_error: nil
          })
      }
    })

    assert {:ok, %{action: :paused_for_review, reason: reason}} =
             MirrorNeuron.recover_job(job_id)

    assert reason =~ "manual recovery"
    wait_until(fn -> agent_paused?(job_id, "worker") end, 2_000)

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
      "nodes" => [
        %{
          "node_id" => "writer",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{"side_effects" => "external", "output_message_type" => nil}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "unsafe-review")

    RedisStore.persist_agent(job_id, "writer", %{
      "agent_id" => "writer",
      "node_id" => "writer",
      "agent_type" => "executor",
      "current_state" => %{"runs" => 0},
      "mailbox_depth" => 0,
      "processed_messages" => 0,
      "inflight_message" => %{
        "id" => "unsafe-message-1",
        "job_id" => job_id,
        "to" => "writer",
        "type" => "write_file",
        "payload" => %{"path" => "/tmp/out"}
      },
      "pending_messages" => [],
      "last_heartbeat_at" => Runtime.timestamp(),
      "parent_job_id" => job_id,
      "metadata" => %{
        "paused" => false,
        "recovery_state" =>
          encoded_checkpoint(%{
            config: %{"side_effects" => "external", "output_message_type" => nil},
            runs: 0,
            agent_state: %{},
            last_output_payload: nil,
            last_result: nil,
            last_error: nil
          })
      }
    })

    assert {:ok, %{action: :paused_for_review, reason: reason}} =
             MirrorNeuron.recover_job(job_id)

    assert reason =~ "unsafe side effects"
    wait_until(fn -> job_runner_pid(job_id, false) != nil end, 2_000)
    wait_until(fn -> agent_paused?(job_id, "writer") end, 2_000)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert get_in(job, ["recovery", "status"]) == "paused_for_review"

    assert {:ok, jobs} = MirrorNeuron.list_jobs(summary: :basic, include_terminal: false)
    summary = Enum.find(jobs, &(&1["job_id"] == job_id))
    assert summary["recovery_status"] == "paused_for_review"
    assert summary["recovery_requires_review"] == true

    assert {:ok, details} = MirrorNeuron.job_details(job_id)
    assert get_in(details, ["summary", "recovery", "status"]) == "paused_for_review"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "local_recovery_paused_for_review"))

    RedisStore.delete_job(job_id)
  end

  test "local recovery pauses corrupted checkpoints without resetting state" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "corrupt_checkpoint_recovery_test",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "role" => "root_coordinator",
          "config" => %{"complete_after" => 2}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "corrupt-checkpoint")

    RedisStore.persist_agent(job_id, "sink", %{
      "agent_id" => "sink",
      "node_id" => "sink",
      "agent_type" => "aggregator",
      "current_state" => %{"messages" => [%{"value" => 1}]},
      "mailbox_depth" => 0,
      "processed_messages" => 1,
      "inflight_message" => nil,
      "pending_messages" => [],
      "last_heartbeat_at" => Runtime.timestamp(),
      "parent_job_id" => job_id,
      "metadata" => %{"paused" => false, "recovery_state" => "not valid base64"}
    })

    assert {:ok, %{action: :paused_for_review, blocked: true}} =
             MirrorNeuron.recover_job(job_id)

    assert job_runner_pid(job_id, false) == nil
    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert job["recovery_reason"] =~ "checkpoints are corrupt"

    assert {:ok, agents} = MirrorNeuron.inspect_agents(job_id)
    assert [%{"current_state" => %{"messages" => [%{"value" => 1}]}}] = agents

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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)

    wait_until(
      fn ->
        match?({:ok, %{"status" => "paused"}}, MirrorNeuron.inspect_job(job_id))
      end,
      2_000
    )

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "cancelled"
    assert get_in(job, ["result", "reason"]) == "cancelled by operator"

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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
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
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        case MirrorNeuron.inspect_agents(job_id) do
          {:ok, agents} ->
            worker = Enum.find(agents, &(&1["agent_id"] == "worker"))
            not is_nil(worker) and is_map(worker["inflight_message"])

          _ ->
            false
        end
      end,
      2_000
    )

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
          "config" => %{"complete_after" => 10}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        {:ok, jobs} = MirrorNeuron.list_jobs(live_only: true, include_terminal: true)
        Enum.any?(jobs, &(&1["job_id"] == job_id))
      end,
      2_000
    )

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
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
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
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
        event["type"] == "agent_message_received" and event["agent_id"] == "sink"
      end)

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

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 3_000)
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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
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

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 5_000)
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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest)

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
            "config" => %{"complete_after" => 4}
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

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 2_000)
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

  test "persists a terminal job record even if the coordinator is gone" do
    job_id = "worker_fallback_test-#{System.unique_integer([:positive])}"

    node = %{
      node_id: "sink",
      agent_type: "aggregator",
      role: "sink",
      config: %{"complete_on_message" => true}
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
      match?({:ok, %{"status" => "completed"}}, MirrorNeuron.inspect_job(job_id))
    end)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "agent_id"]) == "sink"
    assert get_in(job, ["result", "output", "count"]) == 1
    assert get_in(job, ["result", "output", "last_message", "value"]) == "done"

    GenServer.stop(pid)
    RedisStore.delete_job(job_id)
  end

  test "internal snapshots do not emit duplicate checkpoint messages" do
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

    assert {:ok, %{"processed_messages" => 0, "agent_id" => "checkpoint_agent"}} =
             RedisStore.fetch_agent(job_id, "checkpoint_agent")

    refute_receive {:checkpoint_persisted, _snapshot}, 200

    message =
      Message.new(job_id, "external", "checkpoint_agent", "checkpoint", %{"value" => "save"},
        correlation_id: "checkpoint-correlation"
      )

    GenServer.cast(pid, {:deliver, message})

    assert_receive {:checkpoint_persisted, %{"metadata" => %{"explicit_checkpoint" => true}}},
                   1_000

    assert {:ok, %{"metadata" => %{"explicit_checkpoint" => true}}} =
             RedisStore.fetch_agent(job_id, "checkpoint_agent")

    refute_receive {:checkpoint_persisted, _snapshot}, 200

    GenServer.stop(pid)
    Process.exit(coordinator, :kill)
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
            "output_message_type" => nil
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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        case MirrorNeuron.inspect_agents(job_id) do
          {:ok, agents} ->
            worker = Enum.find(agents, &(&1["agent_id"] == "worker"))
            not is_nil(worker) and is_map(worker["inflight_message"])

          _ ->
            false
        end
      end,
      2_000
    )

    [{pid, _}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

    Process.exit(pid, :kill)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 8_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "recovered"]) == true
    assert get_in(job, ["result", "output", "invocation"]) == 2

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "agent_recovery_started"))
    assert Enum.any?(events, &(&1["type"] == "agent_recovered"))

    GenServer.stop(counter_pid)
    RedisStore.delete_job(job_id)
  end

  test "batch job fails after restart policy attempts are exhausted" do
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
            "output_message_type" => nil
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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    for _ <- 1..2 do
      wait_until(fn -> worker_pid(job_id) end, 3_000)

      [{pid, _}] =
        Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

      Process.exit(pid, :kill)
      Process.sleep(100)
    end

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 8_000)
    assert job["status"] == "failed"
    assert get_in(job, ["policy_state", "agents", "worker", "restart_attempts"]) == 1

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
            "output_message_type" => nil
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

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)

    for _ <- 1..2 do
      wait_until(
        fn ->
          case MirrorNeuron.inspect_agents(job_id) do
            {:ok, agents} ->
              worker = Enum.find(agents, &(&1["agent_id"] == "worker"))
              not is_nil(worker) and is_map(worker["inflight_message"])

            _ ->
              false
          end
        end,
        2_000
      )

      # Give the runner a tiny bit of time to execute next_invocation
      Process.sleep(200)

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
      Process.sleep(150)
    end

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.count(events, &(&1["type"] == "agent_recovery_started")) >= 1
    assert Enum.count(events, &(&1["type"] == "agent_recovered")) >= 1

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

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  defp running_status?(job_id) do
    case MirrorNeuron.inspect_job(job_id) do
      {:ok, %{"status" => "running"}} -> true
      _ -> false
    end
  end

  defp worker_pid(job_id) do
    match?(
      [{_pid, _}],
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})
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

  defp agent_current_count(job_id, agent_id) do
    case agent_snapshot(job_id, agent_id) do
      %{"current_state" => %{"count" => count}} when is_integer(count) ->
        count

      %{"current_state" => %{"delegate_state" => %{"count" => count}}} when is_integer(count) ->
        count

      _ ->
        0
    end
  end

  defp agent_snapshot(job_id, agent_id) do
    case MirrorNeuron.inspect_agents(job_id) do
      {:ok, agents} -> Enum.find(agents, &(&1["agent_id"] == agent_id))
      _ -> nil
    end
  end

  defp persist_recoverable_job(manifest, suffix) do
    with {:ok, bundle} <- MirrorNeuron.JobBundle.load(manifest) do
      job_id = "#{Runtime.generate_job_id(bundle.manifest.graph_id)}-#{suffix}"
      manifest_map = MirrorNeuron.Manifest.to_map(bundle.manifest)

      {:ok, _job} =
        RedisStore.persist_job(job_id, %{
          "job_id" => job_id,
          "graph_id" => bundle.manifest.graph_id,
          "job_name" => bundle.manifest.job_name,
          "type" => bundle.manifest.type,
          "required_context_engine" => bundle.manifest.required_context_engine,
          "status" => "running",
          "submitted_at" => Runtime.timestamp(),
          "updated_at" => Runtime.timestamp(),
          "root_agent_ids" => bundle.manifest.entrypoints,
          "placement_policy" => Map.get(bundle.manifest.policies, "placement_policy", "local"),
          "recovery_policy" =>
            Map.get(bundle.manifest.policies, "recovery_mode", "local_restart"),
          "result" => nil,
          "topology" => MirrorNeuron.Manifest.topology(bundle.manifest),
          "manifest" => manifest_map,
          "manifest_ref" => %{}
        })

      {:ok, job_id}
    end
  end

  defp encoded_checkpoint(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  defp redis_key(parts) do
    namespace = MirrorNeuron.Config.string("MN_REDIS_NAMESPACE", :redis_namespace)
    Enum.join([namespace | parts], ":")
  end

  defp agent_unregistered?(job_id, agent_id) do
    Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) == []
  end

  defp job_runner_unregistered?(job_id) do
    Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) == []
  end

  defp checkpoint_proxy(parent, job_id) do
    receive do
      {:agent_checkpoint, agent_id, snapshot} ->
        _ = RedisStore.persist_agent(job_id, agent_id, snapshot)
        send(parent, {:checkpoint_persisted, snapshot})
        checkpoint_proxy(parent, job_id)

      _message ->
        checkpoint_proxy(parent, job_id)
    end
  end

  defp send_counter_messages(job_id, range) do
    Enum.each(range, fn id ->
      assert {:ok, "delivered"} =
               MirrorNeuron.send_message(job_id, "counter", %{
                 "type" => "counter_step",
                 "payload" => %{"id" => id}
               })
    end)
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
