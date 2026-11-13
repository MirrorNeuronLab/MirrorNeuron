defmodule MirrorNeuron.Scheduler.Placement.PlanTest do
  use MirrorNeuron.SchedulerCase, async: false

  alias MirrorNeuron.Manifest

  test "plan inspection helpers return stable defaults" do
    plan = %{
      "placements" => [
        %{
          "agent_id" => "alpha",
          "node" => "node-a@lab",
          "allocations" => %{"devices" => [%{"id" => "gpu-0"}]}
        },
        %{"agent_id" => "beta", "node" => "node-b@lab"}
      ]
    }

    assert Scheduler.target_node(plan, "alpha") == "node-a@lab"
    assert Scheduler.target_node(plan, "missing") == nil

    assert Scheduler.allocation(plan, "alpha") == %{"devices" => [%{"id" => "gpu-0"}]}
    assert Scheduler.allocation(plan, "beta") == %{}

    assert Scheduler.affected_agent_ids(plan, "node-a@lab") == ["alpha"]
    assert Scheduler.affected_agent_ids(%{"placements" => "invalid"}, "node-a@lab") == []
  end

  test "merge_plan replaces matching placements and preserves unrelated ones" do
    existing = %{
      "status" => "planned",
      "placement_count" => 2,
      "placements" => [
        %{"agent_id" => "alpha", "node" => "node-a@lab"},
        %{"agent_id" => "beta", "node" => "node-b@lab"}
      ]
    }

    partial = %{
      "placements" => [
        %{"agent_id" => "beta", "node" => "node-c@lab"},
        %{"agent_id" => "gamma", "node" => "node-c@lab"}
      ]
    }

    merged = Scheduler.merge_plan(existing, partial)

    assert merged["placement_count"] == 3
    assert is_binary(merged["generated_at"])

    assert merged["placements"] == [
             %{"agent_id" => "alpha", "node" => "node-a@lab"},
             %{"agent_id" => "beta", "node" => "node-c@lab"},
             %{"agent_id" => "gamma", "node" => "node-c@lab"}
           ]
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

    paused_jobs = Enum.map(busy_jobs, &Map.put(&1, "status", "paused"))

    assert {:blocked, %{"status" => "runnable_later"}} =
             Scheduler.availability(manifest, nodes: [small_node()], jobs: paused_jobs)

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
end
