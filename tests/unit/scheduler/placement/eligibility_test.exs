defmodule MirrorNeuron.Scheduler.Placement.EligibilityTest do
  use MirrorNeuron.SchedulerCase, async: false

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

  test "ignores object-shaped profile metadata in a node advertisement" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "map-profile-metadata",
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

    node =
      large_node()
      |> Map.put("profiles", %{})
      |> put_in(["hardware", "capabilities"], %{})

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [node], jobs: [])
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = plan["placements"]
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
end
