defmodule MirrorNeuron.Scheduler.Placement.ResourcesTest do
  use MirrorNeuron.SchedulerCase, async: false

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

  test "duplicate explicit ports in one request fail placement clearly" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "duplicate-port",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "ports" => [
                %{"label" => "api", "port" => 8080, "protocol" => "tcp"},
                %{"label" => "metrics", "port" => 8080, "protocol" => "tcp"}
              ]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [large_node()], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "devices, ports, volumes, or runtime driver not available"
  end

  test "automatic ports avoid active and same-request allocations" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "automatic-ports",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "ports" => [
                %{"label" => "mcp", "port" => "auto", "protocol" => "http"},
                %{"label" => "metrics", "port" => "auto", "protocol" => "http"}
              ]
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
              "node" => "large@lab",
              "resources" => %{},
              "allocations" => %{
                "ports" => [
                  %{"label" => "existing", "port" => 49_152, "protocol" => "tcp"}
                ]
              }
            }
          ]
        }
      }
    ]

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [large_node()], jobs: jobs)

    assert [
             %{"port" => 49_153},
             %{"port" => 49_154}
           ] = get_in(plan, ["placements", Access.at(0), "allocations", "ports"])
  end

  test "automatic ports honor the runtime node's published range" do
    previous_start = System.get_env("MN_AUTO_PORT_START")
    previous_end = System.get_env("MN_AUTO_PORT_END")

    try do
      System.put_env("MN_AUTO_PORT_START", "62000")
      System.put_env("MN_AUTO_PORT_END", "62001")

      {:ok, manifest} =
        load_manifest(%{
          "manifest_version" => "1.0",
          "graph_id" => "published-automatic-ports",
          "entrypoints" => ["worker"],
          "nodes" => [
            %{
              "node_id" => "worker",
              "agent_type" => "executor",
              "role" => "root",
              "resources" => %{
                "ports" => [
                  %{"label" => "mcp", "port" => "auto", "protocol" => "http"}
                ]
              }
            }
          ],
          "edges" => [],
          "policies" => %{"recovery_mode" => "local_restart"}
        })

      assert {:ok, plan} = Scheduler.plan(manifest, nodes: [large_node()], jobs: [])

      assert [%{"port" => 62_000}] =
               get_in(plan, ["placements", Access.at(0), "allocations", "ports"])
    after
      restore_env("MN_AUTO_PORT_START", previous_start)
      restore_env("MN_AUTO_PORT_END", previous_end)
    end
  end

  test "automatic ports are released with terminal jobs and fail when the range is exhausted" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "automatic-port-lifecycle",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "ports" => [%{"label" => "mcp", "port" => "auto", "protocol" => "http"}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    terminal_job = %{
      "job_id" => "completed",
      "status" => "completed",
      "scheduler" => %{
        "placements" => [
          %{
            "agent_id" => "completed",
            "node" => "large@lab",
            "allocations" => %{
              "ports" => [%{"label" => "old", "port" => 49_152, "protocol" => "http"}]
            }
          }
        ]
      }
    }

    assert {:ok, plan} =
             Scheduler.plan(manifest, nodes: [large_node()], jobs: [terminal_job])

    assert [%{"port" => 49_152}] =
             get_in(plan, ["placements", Access.at(0), "allocations", "ports"])

    exhausted_job = %{
      "job_id" => "exhausted",
      "status" => "running",
      "scheduler" => %{
        "placements" => [
          %{
            "agent_id" => "exhausted",
            "node" => "large@lab",
            "allocations" => %{
              "ports" =>
                Enum.map(49_152..65_535, fn port ->
                  %{"label" => "port-#{port}", "port" => port, "protocol" => "http"}
                end)
            }
          }
        ]
      }
    }

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [large_node()], jobs: [exhausted_job])

    assert reason =~ "worker"
    assert reason =~ "devices, ports, volumes, or runtime driver not available"
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
end
