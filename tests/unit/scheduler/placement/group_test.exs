defmodule MirrorNeuron.Scheduler.Placement.GroupTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Scheduler.Placement.{Group, Usage}

  defp inventory_node do
    %{
      "capacity" => %{"cpu_cores" => 4, "memory_mb" => 4096, "disk_mb" => 0, "gpu_count" => 0},
      "devices" => [],
      "host_paths" => [],
      "runtime_drivers" => []
    }
  end

  defp demand(id, cpu, port) do
    resources = Map.merge(Usage.empty_resources(), %{"cpu_cores" => cpu, "memory_mb" => 1024})

    %{
      "agent_id" => id,
      "resources" => resources,
      "resource_request" => %{"resources" => resources, "ports" => [%{"port" => port}]}
    }
  end

  test "group placement respects existing usage and reports only the new group's demand" do
    used =
      Usage.add_usage(Usage.empty_usage(), %{"cpu_cores" => 1}, %{"ports" => [%{"port" => 9000}]})

    assert {:ok, plan} =
             Group.group_node_plan(
               inventory_node(),
               [demand("a", 1, 9001), demand("b", 2, 9002)],
               used,
               fn _ -> true end
             )

    assert plan["resources"]["cpu_cores"] == 3
    assert plan["usage"]["resources"]["cpu_cores"] == 4
    assert plan["usage"]["ports"] == MapSet.new(["tcp:9000", "tcp:9001", "tcp:9002"])
    assert Map.keys(plan["allocations"]) |> Enum.sort() == ["a", "b"]
  end

  test "a group cannot partially fit when a later worker exhausts capacity or repeats a port" do
    for second <- [demand("b", 3, 9001), demand("b", 1, 9000)] do
      assert :error =
               Group.group_node_plan(
                 inventory_node(),
                 [demand("a", 2, 9000), second],
                 Usage.empty_usage(),
                 fn _ -> true end
               )
    end

    assert {:ok, plan} =
             Group.group_node_plan(
               inventory_node(),
               [demand("fresh", 4, 9000)],
               Usage.empty_usage(),
               fn _ -> true end
             )

    assert Map.keys(plan["allocations"]) == ["fresh"]
  end

  test "every worker must satisfy the node's eligibility predicate" do
    assert :error =
             Group.group_node_plan(
               inventory_node(),
               [demand("allowed", 1, 9000), demand("denied", 1, 9001)],
               Usage.empty_usage(),
               &(&1["agent_id"] == "allowed")
             )
  end
end
