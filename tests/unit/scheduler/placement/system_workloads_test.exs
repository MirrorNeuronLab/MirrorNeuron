defmodule MirrorNeuron.Scheduler.Placement.SystemWorkloadsTest do
  use MirrorNeuron.SchedulerCase, async: false

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
end
