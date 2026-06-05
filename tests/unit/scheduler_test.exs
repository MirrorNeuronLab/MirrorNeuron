defmodule MirrorNeuron.SchedulerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.ModelCatalog
  alias MirrorNeuron.Scheduler

  defmodule ResourceStore do
    def fetch_resource_limits, do: {:error, "not configured"}
  end

  setup do
    previous_profiles = Application.get_env(:mirror_neuron, :execution_profiles)

    Application.put_env(:mirror_neuron, :resource_limits_store, ResourceStore)

    on_exit(fn ->
      Application.delete_env(:mirror_neuron, :resource_limits_store)

      if is_nil(previous_profiles) do
        Application.delete_env(:mirror_neuron, :execution_profiles)
      else
        Application.put_env(:mirror_neuron, :execution_profiles, previous_profiles)
      end
    end)

    :ok
  end

  test "binpack chooses the tightest healthy node that satisfies resources" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "binpack",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 2, "memory_mb" => 2048}
          }
        ],
        "edges" => [],
        "policies" => %{
          "recovery_mode" => "local_restart",
          "job_type" => "batch",
          "scheduler" => %{"strategy" => "binpack"}
        }
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [large_node(), small_node()], jobs: [])

    assert plan["status"] == "planned"
    assert plan["job_type"] == "batch"
    assert [%{"agent_id" => "worker", "node" => "small@lab"}] = plan["placements"]
  end

  test "manifest type service is the default scheduler job type" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "service-default",
        "type" => "service",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node()], jobs: [])
    assert plan["job_type"] == "service"
  end

  test "constraints and GPU requirements filter candidate nodes" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "cuda-only",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"gpu_count" => 1, "memory_gb" => 8},
            "constraints" => [
              %{"attribute" => "capabilities", "operator" => "contains", "value" => "cuda"}
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), gpu_node()], jobs: [])

    assert [%{"agent_id" => "worker", "node" => "gpu@lab"}] = plan["placements"]
  end

  test "device-style GPU resources are counted during placement" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "multi-gpu-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "cpu" => 1000,
              "memory_gb" => 4,
              "devices" => [%{"type" => "nvidia/gpu", "count" => 2}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [gpu_node(), multi_gpu_node()],
               jobs: []
             )

    assert [
             %{
               "agent_id" => "worker",
               "node" => "multi-gpu@lab",
               "resources" => %{"cpu_cores" => 1.0, "memory_mb" => 4096, "gpu_count" => 2}
             }
           ] = plan["placements"]
  end

  test "active job placements reserve capacity for new plans" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "reserved-capacity",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 2, "memory_mb" => 2048}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    jobs = [
      %{
        "status" => "running",
        "scheduler" => %{
          "placements" => [
            %{
              "agent_id" => "existing",
              "node" => "small@lab",
              "resources" => %{"cpu_cores" => 3, "memory_mb" => 3072}
            }
          ]
        }
      }
    ]

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: jobs)

    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = plan["placements"]
  end

  test "ignore_job_ids removes stale capacity from replans" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "ignore-self",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 2, "memory_mb" => 2048}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    jobs = [
      %{
        "job_id" => "same-job",
        "status" => "running",
        "scheduler" => %{
          "placements" => [
            %{
              "agent_id" => "worker",
              "node" => "small@lab",
              "resources" => %{"cpu_cores" => 3, "memory_mb" => 3072}
            }
          ]
        }
      }
    ]

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), large_node()],
               jobs: jobs,
               ignore_job_ids: ["same-job"]
             )

    assert [%{"agent_id" => "worker", "node" => "small@lab"}] = plan["placements"]
  end

  test "exclude_nodes prevents placement on failed node" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "exclude-node",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 2, "memory_mb" => 2048}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), large_node()],
               jobs: [],
               exclude_nodes: ["small@lab"]
             )

    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = plan["placements"]
  end

  test "maintenance draining and ineligible nodes are not schedulable" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "cordoned-node",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    nodes = [
      small_node() |> Map.put("status", "maintenance") |> Map.put("scheduling_eligible", false),
      large_node() |> Map.put("status", "draining") |> Map.put("scheduling_eligible", false),
      gpu_node() |> Map.put("scheduling_eligible", false)
    ]

    assert {:error, "placement_failed: no schedulable runtime nodes are available"} =
             Scheduler.plan(manifest, nodes: nodes, jobs: [])

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: nodes ++ [large_node()],
               jobs: []
             )

    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = plan["placements"]
  end

  test "only_agent_ids creates partial plans for affected agents" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "partial-plan",
        "entrypoints" => ["first"],
        "nodes" => [
          %{
            "node_id" => "first",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512}
          },
          %{
            "node_id" => "second",
            "agent_type" => "executor",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, partial} =
             Scheduler.plan(manifest,
               nodes: [small_node(), large_node()],
               jobs: [],
               only_agent_ids: ["second"]
             )

    assert [%{"agent_id" => "second"}] = partial["placements"]
  end

  test "system jobs place one copy on every eligible node" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "system-everywhere",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart", "job_type" => "system"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    assert plan["job_type"] == "system"
    assert plan["system_count"] == 2
    assert plan["system_targets"] == ["small@lab", "large@lab"]

    assert Enum.map(plan["placements"], & &1["agent_id"]) == [
             "worker@small@lab",
             "worker@large@lab"
           ]

    assert Enum.all?(plan["placements"], &(&1["source_agent_id"] == "worker"))
  end

  test "sysbatch schedules the whole group only on nodes that can fit it" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "sysbatch-group-fit",
        "entrypoints" => ["first"],
        "nodes" => [
          %{
            "node_id" => "first",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 3, "memory_mb" => 512}
          },
          %{
            "node_id" => "second",
            "agent_type" => "executor",
            "resources" => %{"cpu_cores" => 3, "memory_mb" => 512}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart", "job_type" => "sysbatch"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    assert plan["job_type"] == "sysbatch"
    assert plan["system_targets"] == ["large@lab"]

    assert Enum.map(plan["placements"], & &1["agent_id"]) == [
             "first@large@lab",
             "second@large@lab"
           ]
  end

  test "execution profiles participate in placement eligibility" do
    Application.put_env(:mirror_neuron, :execution_profiles, %{
      "mlx-metal" => %{"gpu" => true, "required_capabilities" => ["metal"]}
    })

    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "profile-placement",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "config" => %{"execution_profile" => "mlx-metal"},
            "resources" => %{"memory_mb" => 1024}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    nodes = [
      Map.merge(large_node(), %{"profiles" => [], "capabilities" => ["cpu"]}),
      gpu_node()
      |> Map.put("profiles", ["mlx-metal"])
      |> Map.put("capabilities", ["metal", "llm"])
    ]

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: nodes, jobs: [])

    assert [%{"agent_id" => "worker", "node" => "gpu@lab"}] = plan["placements"]
  end

  test "returns placement failure when no node has enough resources" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "too-large",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"memory_mb" => 131_072}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "insufficient resources"
  end

  test "node-scoped service requirements filter candidate nodes" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "service-aware-placement",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "requires_services" => [%{"name" => "ollama", "tags" => ["gpu"]}]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    services = [
      %{
        "id" => "svc-1",
        "name" => "ollama",
        "node" => "gpu@lab",
        "status" => "passing",
        "tags" => ["gpu"]
      }
    ]

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), gpu_node()],
               jobs: [],
               service_instances: services
             )

    assert [%{"agent_id" => "worker", "node" => "gpu@lab"}] = plan["placements"]
  end

  test "node-scoped service requirements fail when no healthy service matches" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "service-blocked-placement",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "requires_services" => [%{"name" => "vector-db"}]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest,
               nodes: [small_node(), gpu_node()],
               jobs: [],
               service_instances: [
                 %{
                   "id" => "svc-1",
                   "name" => "vector-db",
                   "node" => "gpu@lab",
                   "status" => "critical"
                 }
               ]
             )

    assert reason =~ "required services not available"
  end

  test "runtime model inference routes LLM workers to advertised high-end GPU model services" do
    {:ok, manifest} =
      Manifest.load(%{
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
            "role" => "root"
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
  end

  test "runtime model inference returns actionable failure when model service is not advertised" do
    {:ok, manifest} =
      Manifest.load(%{
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

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest,
               nodes: [h100_node()],
               jobs: [],
               service_instances: []
             )

    assert reason =~ "ollama/nemotron3:33b"
    assert reason =~ "service ollama"
    assert reason =~ "capability any of"
    assert reason =~ "required services not available"
  end

  test "service model inference routes audio services to nodes that advertise ASR and TTS" do
    {:ok, manifest} =
      Manifest.load(%{
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
               nodes: [small_node(), gpu_node()],
               jobs: [],
               service_instances: [
                 model_service("otterdesk-voice-asr:default", "gpu@lab"),
                 model_service("otterdesk-voice-tts:default", "gpu@lab")
               ]
             )

    assert [%{"node" => "gpu@lab", "resources" => %{"gpu_count" => 0}}] =
             plan["placements"]
  end

  test "CUDA and Metal device requests only place on matching device drivers" do
    {:ok, cuda_manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "cuda-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [
                %{"kind" => "gpu", "driver" => "cuda", "min_memory_mb" => 16_000}
              ]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, cuda_plan} =
             Scheduler.plan(cuda_manifest, nodes: [metal_node(), cuda_node()], jobs: [])

    assert [%{"node" => "cuda@lab", "allocations" => %{"devices" => [cuda_device]}}] =
             cuda_plan["placements"]

    assert cuda_device["id"] == "cuda-0"
    assert cuda_device["driver"] == "cuda"

    {:ok, metal_manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "metal-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"devices" => [%{"kind" => "gpu", "driver" => "metal"}]}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, metal_plan} =
             Scheduler.plan(metal_manifest, nodes: [cuda_node(), metal_node()], jobs: [])

    assert [%{"node" => "metal@lab", "allocations" => %{"devices" => [metal_device]}}] =
             metal_plan["placements"]

    assert metal_device["driver"] == "metal"
  end

  test "vendor-qualified GPU device type avoids mismatched advertised vendors" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "vendor-device-type",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"devices" => [%{"type" => "nvidia/gpu"}]}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [metal_node(), cuda_node()], jobs: [])
    assert [%{"node" => "cuda@lab"}] = plan["placements"]
  end

  test "allocated device ids and explicit ports are exclusive across active placements" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "exclusive-allocation",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [%{"kind" => "gpu", "driver" => "cuda"}],
              "ports" => [%{"label" => "api", "port" => 8080, "protocol" => "tcp"}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    jobs = [
      %{
        "job_id" => "existing",
        "status" => "running",
        "scheduler" => %{
          "placements" => [
            %{
              "agent_id" => "existing",
              "node" => "cuda@lab",
              "resources" => %{"gpu_count" => 1},
              "allocations" => %{
                "devices" => [%{"id" => "cuda-0", "driver" => "cuda"}],
                "ports" => [%{"label" => "api", "port" => 8080, "protocol" => "tcp"}]
              }
            }
          ]
        }
      }
    ]

    assert {:ok, plan} =
             Scheduler.plan(manifest, nodes: [cuda_node(), cuda_node("cuda-2@lab")], jobs: jobs)

    assert [%{"node" => "cuda-2@lab"}] = plan["placements"]

    {:ok, device_manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "exclusive-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"devices" => [%{"kind" => "gpu", "driver" => "cuda"}]}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, device_plan} = Scheduler.plan(device_manifest, nodes: [cuda_node()], jobs: jobs)
    assert [%{"allocations" => %{"devices" => [%{"id" => "cuda-1"}]}}] = device_plan["placements"]
  end

  test "host volumes and runtime drivers filter candidate nodes" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "volume-driver",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "runtime_driver" => "openshell",
              "volumes" => [
                %{
                  "name" => "models",
                  "source" => "/srv/models",
                  "target" => "/models",
                  "mode" => "ro",
                  "type" => "host"
                }
              ]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [
                 Map.put(large_node(), "runtime_drivers", ["host_local"]),
                 large_node()
                 |> Map.put("name", "openshell@lab")
                 |> Map.put("runtime_drivers", ["host_local", "openshell"])
                 |> Map.put("host_paths", ["/srv"])
               ],
               jobs: []
             )

    assert [
             %{
               "node" => "openshell@lab",
               "allocations" => %{
                 "runtime_driver" => "openshell",
                 "volumes" => [%{"name" => "models", "source" => "/srv/models"}]
               }
             }
           ] = plan["placements"]
  end

  test "manifests serialize scheduler resources and constraints" do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "serialize-scheduling",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1},
            "constraints" => [%{"attribute" => "os", "operator" => "==", "value" => "linux"}]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    worker = Manifest.to_map(manifest)["nodes"] |> List.first()

    assert worker["resources"] == %{"cpu_cores" => 1}

    assert worker["constraints"] == [
             %{"attribute" => "os", "operator" => "==", "value" => "linux"}
           ]
  end

  defp small_node do
    %{
      "name" => "small@lab",
      "status" => "healthy",
      "capabilities" => ["cpu"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 4},
        "memory" => %{"available_mb" => 4096},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  defp large_node do
    %{
      "name" => "large@lab",
      "status" => "healthy",
      "capabilities" => ["cpu"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 8},
        "memory" => %{"available_mb" => 16_384},
        "disk" => %{"available_mb" => 200_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  defp gpu_node do
    %{
      "name" => "gpu@lab",
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 16},
        "memory" => %{"available_mb" => 65_536},
        "disk" => %{"available_mb" => 500_000},
        "gpu" => [%{"name" => "NVIDIA RTX"}]
      }
    }
  end

  defp multi_gpu_node do
    %{
      "name" => "multi-gpu@lab",
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 16},
        "memory" => %{"available_mb" => 65_536},
        "disk" => %{"available_mb" => 500_000},
        "gpu" => [%{"name" => "GPU 1"}, %{"name" => "GPU 2"}]
      }
    }
  end

  defp cuda_node(name \\ "cuda@lab") do
    %{
      "name" => name,
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 16},
        "memory" => %{"available_mb" => 65_536},
        "disk" => %{"available_mb" => 500_000},
        "gpu" => [
          %{
            "id" => "cuda-0",
            "index" => 0,
            "name" => "NVIDIA RTX 4090",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 24_576,
            "memory_free_mb" => 20_000,
            "capabilities" => ["gpu", "cuda", "nvidia"]
          },
          %{
            "id" => "cuda-1",
            "index" => 1,
            "name" => "NVIDIA RTX 3090",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 24_576,
            "memory_free_mb" => 12_000,
            "capabilities" => ["gpu", "cuda", "nvidia"]
          }
        ]
      }
    }
  end

  defp h100_node do
    %{
      "name" => "h100@lab",
      "status" => "healthy",
      "capabilities" => ["cuda", "nvidia", "nvidia-h100", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 32},
        "memory" => %{"available_mb" => 131_072},
        "disk" => %{"available_mb" => 1_000_000},
        "gpu" => [
          %{
            "id" => "h100-0",
            "index" => 0,
            "name" => "NVIDIA H100 80GB HBM3",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 81_920,
            "memory_free_mb" => 80_000,
            "capabilities" => ["gpu", "cuda", "nvidia", "nvidia-h100"]
          }
        ]
      }
    }
  end

  defp model_service(model, node) do
    model
    |> ModelCatalog.resolve!()
    |> ModelCatalog.service_instance(node)
  end

  defp metal_node do
    %{
      "name" => "metal@lab",
      "status" => "healthy",
      "capabilities" => ["metal", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
        "platform" => %{"os" => "darwin"},
        "cpu" => %{"logical_processors" => 12},
        "memory" => %{"available_mb" => 32_768},
        "disk" => %{"available_mb" => 300_000},
        "gpu" => [
          %{
            "id" => "metal-0",
            "index" => 0,
            "name" => "Apple M2 Max",
            "kind" => "gpu",
            "type" => "apple/gpu",
            "vendor" => "apple",
            "driver" => "metal",
            "memory_total_mb" => 32_768,
            "memory_free_mb" => 20_000,
            "capabilities" => ["gpu", "apple", "metal"]
          }
        ]
      }
    }
  end
end
