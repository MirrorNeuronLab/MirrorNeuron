defmodule MirrorNeuron.Scheduler.Placement.ModelsTest do
  use MirrorNeuron.SchedulerCase, async: false

  test "runtime model inference routes LLM workers to advertised high-end GPU model services" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "smart-llm-placement",
        "runtime" => %{
          "models" => %{
            "primary" => %{
              "provider" => "docker_model_runner",
              "model" => "otterdesk-voice-llm:default"
            }
          }
        },
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "requires_services" => [model_service_requirement("otterdesk-voice-llm:default")],
            "placement_requirements" => %{
              "models" => [
                model_placement_requirement("otterdesk-voice-llm:default", [
                  "nvidia-h100",
                  "nvidia-gb10"
                ])
              ]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), cuda_node(), h100_node()],
               jobs: [],
               service_instances: [
                 model_service("otterdesk-voice-llm:default", "h100@lab")
               ]
             )

    assert [
             %{
               "agent_id" => "worker",
               "node" => "h100@lab",
               "resources" => %{},
               "allocations" => %{"devices" => []},
               "placement_requirements" => %{"models" => [model]}
             }
           ] = plan["placements"]

    assert model["id"] == "otterdesk-voice-llm:default"
    assert get_in(model, ["service", "name"]) == "docker-model-runner"
    assert "nvidia-h100" in model["required_capabilities"]
    assert "nvidia-gb10" in model["required_capabilities"]
  end

  test "runtime model inference co-locates default DMR workers with model service node" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "co-located-dmr-worker",
        "runtime" => %{
          "models" => %{
            "primary" => %{
              "provider" => "docker_model_runner",
              "model" => "nemotron-3.5-bolt-e4b:q4_k_m"
            }
          }
        },
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "requires_services" => [model_service_requirement("nemotron-3.5-bolt-e4b:q4_k_m")],
            "placement_requirements" => %{
              "models" => [model_placement_requirement("nemotron-3.5-bolt-e4b:q4_k_m")]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [large_node(), small_node()],
               jobs: [],
               service_instances: [
                 model_service("nemotron-3.5-bolt-e4b:q4_k_m", "small@lab")
               ]
             )

    assert [
             %{
               "agent_id" => "worker",
               "node" => "small@lab",
               "resources" => %{},
               "allocations" => %{"devices" => []},
               "placement_requirements" => %{"models" => [model]}
             }
           ] = plan["placements"]

    assert model["id"] == "nemotron-3.5-bolt-e4b:q4_k_m"
    assert get_in(model, ["service", "name"]) == "docker-model-runner"
  end

  test "runtime model inference shares one DMR service across multiple LLM workers" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "shared-dmr-service-workers",
        "runtime" => %{
          "models" => %{
            "primary" => %{
              "provider" => "docker_model_runner",
              "model" => "nemotron3"
            }
          }
        },
        "entrypoints" => ["worker_a"],
        "nodes" => [
          %{
            "node_id" => "worker_a",
            "agent_type" => "executor",
            "requires_services" => [model_service_requirement("nemotron3")],
            "placement_requirements" => %{"models" => [model_placement_requirement("nemotron3")]}
          },
          %{
            "node_id" => "worker_b",
            "agent_type" => "executor",
            "requires_services" => [model_service_requirement("nemotron3")],
            "placement_requirements" => %{"models" => [model_placement_requirement("nemotron3")]}
          },
          %{
            "node_id" => "worker_c",
            "agent_type" => "executor",
            "requires_services" => [model_service_requirement("nemotron3")],
            "placement_requirements" => %{"models" => [model_placement_requirement("nemotron3")]}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), put_gpu_memory(h100_node(), 60_000)],
               jobs: [],
               service_instances: [
                 model_service("nemotron3", "h100@lab")
               ]
             )

    assert Enum.map(plan["placements"], & &1["node"]) == ["h100@lab", "h100@lab", "h100@lab"]
    assert Enum.all?(plan["placements"], &(get_in(&1, ["allocations", "devices"]) == []))
    assert Enum.all?(plan["placements"], &(get_in(&1, ["resources", "gpu_count"]) in [nil, 0]))
  end

  test "runtime model inference ignores stale services on offline GPU nodes" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "stale-model-service",
        "runtime" => %{
          "models" => %{
            "primary" => %{
              "provider" => "docker_model_runner",
              "model" => "otterdesk-voice-llm:default"
            }
          }
        },
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "requires_services" => [model_service_requirement("otterdesk-voice-llm:default")],
            "placement_requirements" => %{
              "models" => [model_placement_requirement("otterdesk-voice-llm:default")]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    offline_h100 =
      h100_node()
      |> Map.put("status", "offline")

    healthy_h100_without_service =
      h100_node()
      |> Map.put("name", "h100-fresh@lab")

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest,
               nodes: [small_node(), healthy_h100_without_service, offline_h100],
               jobs: [],
               service_instances: [
                 model_service("otterdesk-voice-llm:default", "h100@lab")
               ]
             )

    assert reason =~ "worker"
    assert reason =~ "small@lab: required services not available"
    assert reason =~ "h100-fresh@lab: required services not available"
    assert reason =~ "h100@lab: status \"offline\""
    refute reason =~ "placed"
  end

  test "runtime model inference ignores non-DMR model providers" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "missing-model-service",
        "runtime" => %{
          "models" => %{
            "primary" => %{
              "provider" => "ollama",
              "model" => "ollama/nemotron3:33b"
            }
          }
        },
        "entrypoints" => ["worker"],
        "nodes" => [%{"node_id" => "worker", "agent_type" => "executor"}],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [h100_node()],
               jobs: [],
               service_instances: []
             )

    assert [
             %{
               "agent_id" => "worker",
               "node" => "h100@lab",
               "resources" => %{},
               "allocations" => %{"devices" => []},
               "placement_requirements" => %{"models" => []}
             }
           ] = plan["placements"]
  end

  test "runtime model environment keys do not create core model requirements" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "runtime-env-model-placement",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "config" => %{
              "environment" => %{
                "MN_LLM_RUNTIME_MODEL" => "otterdesk-voice-llm:default",
                "MN_CONTEXT_ENGINE_MODEL" => "nemotron-3.5-bolt-e4b:q4_k_m",
                "MN_LLM_MODEL" => "ollama/nemotron3:33b",
                "OLLAMA_MODEL" => "ollama/nemotron3:33b",
                "VL_MODEL_NAME" => "ollama/nemotron3:33b"
              }
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [h100_node()],
               jobs: [],
               service_instances: [
                 model_service("otterdesk-voice-llm:default", "h100@lab"),
                 model_service("nemotron-3.5-bolt-e4b:q4_k_m", "h100@lab")
               ]
             )

    assert [%{"placement_requirements" => %{"models" => []}}] = plan["placements"]
  end

  test "explicit service requirements drive model placement independently of config refs" do
    blueprint_config =
      Jason.encode!(%{
        "llm" => %{
          "enabled" => true,
          "provider" => "docker_model_runner",
          "model" => "nemotron-3.5-bolt-e4b:q4_k_m"
        }
      })

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "runtime-env-model-override",
        "entrypoints" => ["video_worker"],
        "nodes" => [
          %{
            "node_id" => "video_worker",
            "agent_type" => "executor",
            "role" => "root",
            "config" => %{
              "environment" => %{
                "MN_LLM_RUNTIME_MODEL" => "otterdesk-video-watch:default",
                "MN_BLUEPRINT_CONFIG_JSON" => blueprint_config
              }
            },
            "requires_services" => [model_service_requirement("otterdesk-video-watch:default")],
            "placement_requirements" => %{
              "models" => [model_placement_requirement("otterdesk-video-watch:default")]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [h100_node()],
               jobs: [],
               service_instances: [
                 model_service("otterdesk-video-watch:default", "h100@lab")
               ]
             )

    assert [%{"placement_requirements" => %{"models" => [model]}}] = plan["placements"]
    assert model["id"] == "otterdesk-video-watch:default"
  end

  test "service model inference ignores NVIDIA service providers" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "smart-audio-placement",
        "runtime" => %{
          "models" => %{
            "asr" => %{"provider" => "nvidia_service", "model" => "otterdesk-voice-asr:default"},
            "tts" => %{"provider" => "nvidia_service", "model" => "otterdesk-voice-tts:default"}
          }
        },
        "entrypoints" => ["voice"],
        "nodes" => [%{"node_id" => "voice", "agent_type" => "executor"}],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node()],
               jobs: [],
               service_instances: []
             )

    assert [%{"node" => "small@lab", "resources" => %{}}] =
             plan["placements"]
  end
end
