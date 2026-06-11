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

  defp load_manifest(raw) when is_map(raw) do
    raw =
      if Map.has_key?(raw, "flow") do
        raw
      else
        raw
        |> Map.put("flow", %{
          "nodes" => Map.get(raw, "nodes", []),
          "edges" => Map.get(raw, "edges", [])
        })
        |> Map.delete("nodes")
        |> Map.delete("edges")
      end

    Manifest.load(raw)
  end

  test "binpack prefers the more powerful healthy node by default" do
    {:ok, manifest} =
      load_manifest(%{
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

    assert [
             %{
               "agent_id" => "worker",
               "node" => "large@lab",
               "power_score" => power_score
             }
           ] = placements = plan["placements"]

    assert power_score > 0
    refute Map.has_key?(hd(placements), "preferred_node_status")
  end

  test "valid preferred node hint wins when the hinted node can fit the agent" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "preferred-node",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512},
            "policies" => %{
              "scheduler" => %{"preferred_node" => "small@lab"}
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [large_node(), small_node()], jobs: [])

    assert [
             %{
               "agent_id" => "worker",
               "node" => "small@lab",
               "preferred_node" => "small@lab",
               "preferred_node_status" => "honored"
             }
           ] = plan["placements"]
  end

  test "missing or exhausted preferred node hint falls back to automatic placement" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "preferred-node-fallback",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 2, "memory_mb" => 2048},
            "policies" => %{
              "scheduler" => %{"preferred_node" => "missing@lab"}
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    assert [
             %{
               "agent_id" => "worker",
               "node" => "large@lab",
               "preferred_node" => "missing@lab",
               "preferred_node_status" => "fallback"
             }
           ] = plan["placements"]

    busy_jobs = [
      %{
        "status" => "running",
        "scheduler" => %{
          "placements" => [
            %{
              "agent_id" => "busy",
              "node" => "small@lab",
              "resources" => %{"cpu_cores" => 4, "memory_mb" => 4096}
            }
          ]
        }
      }
    ]

    {:ok, preferred_small_manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "preferred-node-exhausted",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512},
            "policies" => %{
              "scheduler" => %{"preferred_node" => "small@lab"}
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, exhausted_plan} =
             Scheduler.plan(preferred_small_manifest,
               nodes: [small_node(), large_node()],
               jobs: busy_jobs
             )

    assert [
             %{
               "agent_id" => "worker",
               "node" => "large@lab",
               "preferred_node" => "small@lab",
               "preferred_node_status" => "fallback"
             }
           ] = exhausted_plan["placements"]
  end

  test "valid per-agent hints skip whole-job co-location and place agents separately" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "conflicting-preferred-nodes",
        "entrypoints" => ["video"],
        "nodes" => [
          %{
            "node_id" => "video",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512},
            "policies" => %{"scheduler" => %{"preferred_node" => "large@lab"}}
          },
          %{
            "node_id" => "report",
            "agent_type" => "executor",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512},
            "policies" => %{"scheduler" => %{"preferred_node" => "small@lab"}}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    placements = Map.new(plan["placements"], &{&1["agent_id"], &1})

    assert placements["video"]["node"] == "large@lab"
    assert placements["video"]["locality"] == "agent_spillover"
    assert placements["video"]["preferred_node_status"] == "honored"

    assert placements["report"]["node"] == "small@lab"
    assert placements["report"]["locality"] == "agent_spillover"
    assert placements["report"]["preferred_node_status"] == "honored"
  end

  test "prefers nodes with required blob refs after hard requirements match" do
    sha256 = String.duplicate("b", 64)

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "blob-locality",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "config" => %{}}
        ],
        "edges" => [],
        "metadata" => %{
          "mn_artifacts" => %{
            "blob_refs" => [
              %{
                "type" => "blob_ref",
                "sha256" => sha256,
                "size_bytes" => 10,
                "payload_path" => "input/video.mp4",
                "locations" => [
                  %{"node" => "node-b@lab", "storage" => "node_local", "path" => "bb/#{sha256}"}
                ]
              }
            ]
          }
        }
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [
                 %{"name" => "node-a@lab", "status" => "healthy", "hardware" => %{}},
                 %{"name" => "node-b@lab", "status" => "healthy", "hardware" => %{}}
               ],
               jobs: [],
               lookup_node_state: false
             )

    assert [%{"agent_id" => "worker", "node" => "node-b@lab", "blob_locality" => locality}] =
             plan["placements"]

    assert locality["local_count"] == 1
    assert locality["required_count"] == 1
  end

  test "treats shared filesystem blob refs as available on every node" do
    sha256 = String.duplicate("e", 64)

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "shared-blob-locality",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "config" => %{}}
        ],
        "edges" => [],
        "metadata" => %{
          "mn_artifacts" => %{
            "blob_refs" => [
              %{
                "type" => "blob_ref",
                "sha256" => sha256,
                "size_bytes" => 10,
                "payload_path" => "input/video.mp4",
                "locations" => [
                  %{"storage" => "shared_fs", "root" => "blob_store", "path" => "ee/#{sha256}"}
                ]
              }
            ]
          }
        }
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [
                 %{"name" => "node-a@lab", "status" => "healthy", "hardware" => %{}},
                 %{"name" => "node-b@lab", "status" => "healthy", "hardware" => %{}}
               ],
               jobs: [],
               lookup_node_state: false
             )

    assert [%{"agent_id" => "worker", "blob_locality" => locality}] = plan["placements"]
    assert locality["local_count"] == 1
    assert locality["required_count"] == 1
  end

  test "power-first scoring beats blob locality when both nodes are eligible" do
    sha256 = String.duplicate("c", 64)

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "power-before-blob",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "config" => %{}}
        ],
        "edges" => [],
        "metadata" => %{
          "mn_artifacts" => %{
            "blob_refs" => [
              %{
                "type" => "blob_ref",
                "sha256" => sha256,
                "size_bytes" => 10,
                "payload_path" => "input/video.mp4",
                "locations" => [
                  %{"node" => "small@lab", "storage" => "node_local", "path" => "cc/#{sha256}"}
                ]
              }
            ]
          }
        }
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), large_node()],
               jobs: [],
               lookup_node_state: false
             )

    assert [%{"agent_id" => "worker", "node" => "large@lab", "blob_locality" => locality}] =
             plan["placements"]

    assert locality["local_count"] == 0
    assert locality["required_count"] == 1
  end

  test "manifest type service is the default scheduler job type" do
    {:ok, manifest} =
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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

  test "batch jobs colocate agents on one node before spilling over" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "locality-bias",
        "entrypoints" => ["alpha"],
        "nodes" => [
          %{
            "node_id" => "alpha",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 3, "memory_mb" => 1024}
          },
          %{
            "node_id" => "beta",
            "agent_type" => "executor",
            "resources" => %{"cpu_cores" => 3, "memory_mb" => 1024}
          }
        ],
        "edges" => [],
        "policies" => %{
          "recovery_mode" => "local_restart",
          "scheduler" => %{"strategy" => "binpack"}
        }
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    assert Enum.map(plan["placements"], & &1["node"]) == ["large@lab", "large@lab"]
    assert Enum.all?(plan["placements"], &(&1["locality"] == "job_colocated"))
  end

  test "availability distinguishes busy resources from impossible requirements" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "resource-wait",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 3, "memory_mb" => 1024}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    busy_jobs = [
      %{
        "status" => "running",
        "scheduler" => %{
          "placements" => [
            %{
              "agent_id" => "busy",
              "node" => "small@lab",
              "resources" => %{"cpu_cores" => 2, "memory_mb" => 1024}
            }
          ]
        }
      }
    ]

    assert {:blocked, %{"status" => "runnable_later"}} =
             Scheduler.availability(manifest, nodes: [small_node()], jobs: busy_jobs)

    impossible = %{manifest | nodes: [%{hd(manifest.nodes) | resources: %{"gpu_count" => 1}}]}

    assert {:error, %{"status" => "not_runnable"}} =
             Scheduler.availability(impossible, nodes: [small_node()], jobs: [])
  end

  test "ignore_job_ids removes stale capacity from replans" do
    {:ok, manifest} =
      load_manifest(%{
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

    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = plan["placements"]
  end

  test "exclude_nodes prevents placement on failed node" do
    {:ok, manifest} =
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
              "model" => "gemma4:e2b"
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
               nodes: [large_node(), small_node()],
               jobs: [],
               service_instances: [
                 model_service("gemma4:e2b", "small@lab")
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

    assert model["id"] == "gemma4:e2b"
    assert get_in(model, ["service", "name"]) == "docker-model-runner"
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
        "nodes" => [%{"node_id" => "worker", "agent_type" => "executor"}],
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
    assert reason =~ "small@lab: constraints not matched"
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

  test "runtime model inference only reads runtime model environment keys" do
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
                "MN_CONTEXT_ENGINE_MODEL" => "gemma4:e2b",
                "MN_LLM_MODEL" => "ollama/nemotron3:33b",
                "OLLAMA_MODEL" => "ollama/nemotron3:33b",
                "LITELLM_MODEL" => "ollama/nemotron3:33b",
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
                 model_service("gemma4:e2b", "h100@lab")
               ]
             )

    assert [%{"placement_requirements" => %{"models" => models}}] = plan["placements"]
    assert Enum.map(models, & &1["id"]) == ["otterdesk-voice-llm:default", "gemma4:e2b"]
    refute Enum.any?(models, &(&1["id"] == "ollama/nemotron3:33b"))
  end

  test "runtime model inference lets explicit node model override blueprint default llm" do
    blueprint_config =
      Jason.encode!(%{
        "llm" => %{
          "enabled" => true,
          "provider" => "docker_model_runner",
          "model" => "gemma4:e2b"
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

  test "hardware-derived GPU capabilities are enough for NVIDIA-specific and Metal placement" do
    {:ok, nvidia_manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "hardware-derived-nvidia",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"gpu_count" => 1},
            "constraints" => [
              %{
                "attribute" => "capabilities",
                "operator" => "contains",
                "value" => "nvidia-h100"
              }
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, nvidia_plan} =
             Scheduler.plan(nvidia_manifest,
               nodes: [small_node(), capabilityless_h100_node()],
               jobs: []
             )

    assert [%{"node" => "h100@lab"}] = nvidia_plan["placements"]

    {:ok, metal_manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "hardware-derived-metal",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"gpu_count" => 1},
            "constraints" => [
              %{"attribute" => "capabilities", "operator" => "contains", "value" => "metal"}
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, metal_plan} =
             Scheduler.plan(metal_manifest,
               nodes: [small_node(), capabilityless_metal_node()],
               jobs: []
             )

    assert [%{"node" => "metal@lab"}] = metal_plan["placements"]
  end

  test "GPU-required placement fails instead of falling back to CPU-only nodes" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "gpu-required-no-cpu-fallback",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [%{"kind" => "gpu", "driver" => "cuda", "count" => 1}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "small@lab: insufficient resources"
    assert reason =~ "large@lab: insufficient resources"
  end

  test "GPU-required placement stays blocked while GPU node is offline" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "gpu-required-node-left",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [%{"kind" => "gpu", "driver" => "cuda", "count" => 1}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    offline_gpu =
      cuda_node("gpu-left@lab")
      |> Map.put("status", "offline")
      |> Map.put("scheduling_eligible", false)

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [small_node(), offline_gpu], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "small@lab: insufficient resources"
    assert reason =~ "gpu-left@lab: status \"offline\""

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), cuda_node("gpu-left@lab")],
               jobs: []
             )

    assert [%{"agent_id" => "worker", "node" => "gpu-left@lab"}] = plan["placements"]
  end

  test "GPU device placement follows refreshed node capabilities" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "cuda-capability-refresh",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [%{"kind" => "gpu", "driver" => "cuda"}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    stale_cuda_host =
      cuda_node()
      |> Map.put("capabilities", ["cpu"])
      |> put_in(["hardware", "gpu"], "Unknown or None")

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [small_node(), stale_cuda_host], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "small@lab: insufficient resources"
    assert reason =~ "cuda@lab: insufficient resources"

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), cuda_node()], jobs: [])

    assert [%{"node" => "cuda@lab", "allocations" => %{"devices" => [device]}}] =
             plan["placements"]

    assert device["driver"] == "cuda"
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

  test "CUDA and Metal device requests only place on matching device drivers" do
    {:ok, cuda_manifest} =
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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
      load_manifest(%{
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

  test "docker worker runner infers docker_worker runtime driver" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "docker-worker-driver",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "config" => %{
              "runner_module" => "MirrorNeuron.Runner.DockerWorker",
              "image" => "example/worker:latest"
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
                 |> Map.put("name", "docker@lab")
                 |> Map.put("runtime_drivers", ["host_local", "docker_worker"])
               ],
               jobs: []
             )

    assert [
             %{
               "node" => "docker@lab",
               "allocations" => %{"runtime_driver" => "docker_worker"}
             }
           ] = plan["placements"]
  end

  test "manifests serialize scheduler resources and constraints" do
    {:ok, manifest} =
      load_manifest(%{
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

    worker = Manifest.to_map(manifest) |> get_in(["flow", "nodes"]) |> List.first()

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

  defp capabilityless_h100_node do
    h100_node()
    |> Map.delete("capabilities")
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

  defp capabilityless_metal_node do
    metal_node()
    |> Map.delete("capabilities")
  end
end
