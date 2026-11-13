defmodule MirrorNeuron.Scheduler.Placement.PreferencesTest do
  use MirrorNeuron.SchedulerCase, async: false

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
end
