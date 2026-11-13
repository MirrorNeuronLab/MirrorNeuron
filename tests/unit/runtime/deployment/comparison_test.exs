defmodule MirrorNeuron.Runtime.DeploymentController.ComparisonTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.DeploymentController.Comparison

  test "declaration ordering alone does not trigger a topology replacement" do
    left = manifest()

    right = %{
      left
      | nodes: Enum.reverse(left.nodes),
        edges: Enum.reverse(left.edges),
        entrypoints: Enum.reverse(left.entrypoints)
    }

    assert Comparison.same_topology?(left, right)
    assert Comparison.changed_source_agent_ids(left, right) == []
  end

  test "changing routes or entrypoints requires a topology replacement" do
    left = manifest()
    edge = hd(left.edges)
    refute Comparison.same_topology?(left, %{left | edges: [%{edge | routing_mode: "broadcast"}]})
    refute Comparison.same_topology?(left, %{left | entrypoints: ["sink"]})
  end

  test "configuration changes select only the changed logical agent" do
    left = manifest()
    [worker, sink] = left.nodes
    right = %{left | nodes: [%{worker | config: %{"version" => 2}}, sink]}
    assert Comparison.same_topology?(left, right)
    assert Comparison.changed_source_agent_ids(left, right) == ["worker"]
  end

  test "equivalent atom and string configuration keys do not trigger a rollout" do
    left = manifest()
    [worker, sink] = left.nodes
    right = %{left | nodes: [%{worker | config: %{version: 1}}, sink]}
    assert Comparison.changed_source_agent_ids(left, right) == []
  end

  test "a changed source expands to its runtime allocations without affecting other sources" do
    plan = %{
      "placements" => [
        %{"agent_id" => "worker@a", "source_agent_id" => "worker"},
        %{"agent_id" => "sink"},
        %{"agent_id" => "worker@b", "source_agent_id" => "worker"}
      ]
    }

    assert Comparison.runtime_agent_ids(plan, ["worker"]) == ["worker@a", "worker@b"]
    assert Comparison.runtime_agent_ids(%{}, ["worker"]) == ["worker"]
  end

  defp manifest do
    %Manifest{
      nodes: [
        %{node_id: "worker", agent_type: "executor", config: %{"version" => 1}},
        %{node_id: "sink", agent_type: "step", config: %{}}
      ],
      edges: [
        %{from_node: "worker", to_node: "sink", message_type: "result", routing_mode: "direct"}
      ],
      entrypoints: ["worker", "sink"]
    }
  end
end
