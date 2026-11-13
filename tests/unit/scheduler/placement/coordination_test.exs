defmodule MirrorNeuron.Scheduler.Placement.CoordinationTest do
  use MirrorNeuron.SchedulerCase, async: false

  test "single-node workflow succeeds on one node and a shared-Redis two-node cluster" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "single-node-workflow",
        "metadata" => %{
          "mn_workflow_placement" => %{
            "mode" => "single_node",
            "selected_node" => "large@lab"
          }
        },
        "entrypoints" => ["one"],
        "nodes" =>
          for id <- ["one", "two", "three"] do
            %{
              "node_id" => id,
              "agent_type" => "executor",
              "constraints" => [
                %{"attribute" => "node.name", "operator" => "==", "value" => "large@lab"}
              ]
            }
          end,
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    store = %{
      "identity" => "shared-store",
      "writable_primary" => true,
      "healthy" => true
    }

    one = Map.put(large_node(), "coordination_store", store)

    assert {:ok, one_node_plan} =
             Scheduler.plan(manifest,
               nodes: [one],
               jobs: [],
               coordination_store: store
             )

    assert Enum.uniq(Enum.map(one_node_plan["placements"], & &1["node"])) == ["large@lab"]

    two = Map.put(small_node(), "coordination_store", store)

    assert {:ok, cluster_plan} =
             Scheduler.plan(manifest,
               nodes: [one, two],
               jobs: [],
               coordination_store: store
             )

    assert Enum.uniq(Enum.map(cluster_plan["placements"], & &1["node"])) == ["large@lab"]
  end

  test "coordination-store mismatches and read-only nodes are excluded" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "coordination-store-guard",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "constraints" => [
              %{"attribute" => "node.name", "operator" => "==", "value" => "small@lab"}
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    expected = %{"identity" => "shared-store", "writable_primary" => true}

    divergent =
      Map.put(small_node(), "coordination_store", %{
        "identity" => "other-store",
        "writable_primary" => false
      })

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest,
               nodes: [Map.put(large_node(), "coordination_store", expected), divergent],
               jobs: [],
               coordination_store: expected
             )

    assert reason =~ "coordination store identity"
  end

  test "the local node uses the current coordination-store status over a stale advertisement" do
    local_node = to_string(Node.self())

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "local-coordination-store",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "constraints" => [
              %{"attribute" => "node.name", "operator" => "==", "value" => local_node}
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    current_store = %{"identity" => "current-store", "writable_primary" => true}

    stale_local_node =
      small_node()
      |> Map.put("name", local_node)
      |> Map.put("coordination_store", %{"identity" => "stale-store", "writable_primary" => true})

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [stale_local_node],
               jobs: [],
               coordination_store: current_store
             )

    assert [%{"node" => ^local_node}] = plan["placements"]
  end

  test "Core rejects a single-node manifest whose final plan spans nodes" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "invalid-single-node-workflow",
        "metadata" => %{"mn_workflow_placement" => %{"mode" => "single_node"}},
        "entrypoints" => ["left"],
        "nodes" => [
          %{
            "node_id" => "left",
            "agent_type" => "executor",
            "constraints" => [
              %{"attribute" => "node.name", "operator" => "==", "value" => "small@lab"}
            ]
          },
          %{
            "node_id" => "right",
            "agent_type" => "executor",
            "constraints" => [
              %{"attribute" => "node.name", "operator" => "==", "value" => "large@lab"}
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:error, "placement_failed: single_node_manifest_spans_multiple_nodes:" <> _} =
             Scheduler.plan(manifest,
               nodes: [small_node(), large_node()],
               jobs: []
             )
  end
end
