defmodule MirrorNeuron.SchedulerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Manifest
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
    assert worker["constraints"] == [%{"attribute" => "os", "operator" => "==", "value" => "linux"}]
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
end
