defmodule MirrorNeuron.Runtime.JobTopologyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.JobTopology

  defp manifest do
    %Manifest{
      nodes: [
        %{
          node_id: "a",
          config: %{"key" => "value"},
          agent_type: "worker",
          type: "agent",
          role: "source"
        },
        %{node_id: "b", config: %{}, agent_type: "worker", type: "agent", role: "sink"}
      ],
      edges: [
        %{
          edge_id: "edge",
          from_node: "a",
          to_node: "b",
          message_type: "data",
          routing_mode: "direct",
          conditions: %{}
        }
      ],
      entrypoints: ["a"]
    }
  end

  test "ordinary and unplaced system jobs retain the authored topology" do
    manifest = manifest()

    for plan <- [%{"job_type" => "batch"}, %{"job_type" => "system", "placements" => []}] do
      topology = JobTopology.build(manifest, plan)
      assert topology.nodes == manifest.nodes
      assert topology.edges == manifest.edges
      assert topology.entrypoints == ["a"]
      assert topology.source_agent_ids == %{"a" => "a", "b" => "b"}
      assert topology.system_targets == []
    end
  end

  test "system expansion preserves placement and target order and source configuration" do
    placements =
      for target <- ["z", "a"], source <- ["b", "a"] do
        %{"agent_id" => "#{source}@#{target}", "source_agent_id" => source, "node" => target}
      end

    topology =
      JobTopology.build(manifest(), %{"job_type" => "sysbatch", "placements" => placements})

    assert topology.agent_ids == ["b@z", "a@z", "b@a", "a@a"]
    assert topology.system_targets == ["z", "a"]
    assert topology.entrypoints == ["a@z", "a@a"]

    assert Enum.map(topology.edges, &{&1.from_node, &1.to_node}) == [
             {"a@z", "b@z"},
             {"a@a", "b@a"}
           ]

    assert topology.agents_by_system_target == %{"z" => ["b@z", "a@z"], "a" => ["b@a", "a@a"]}

    assert Enum.at(topology.nodes, 1).config == %{
             "key" => "value",
             "__mirror_neuron_source_node_id" => "a",
             "__mirror_neuron_system_target" => "z"
           }

    snapshot =
      JobTopology.snapshot(%{
        runtime_nodes: topology.nodes,
        runtime_edges: topology.edges,
        runtime_entrypoints: topology.entrypoints,
        source_agent_ids: topology.source_agent_ids,
        system_targets: topology.system_targets
      })

    assert Enum.map(snapshot["nodes"], & &1["source_node_id"]) == ["b", "a", "b", "a"]
    assert snapshot["system_targets"] == ["z", "a"]
    refute Map.has_key?(hd(snapshot["nodes"]), "config")
  end

  test "downstream traversal terminates cycles and preserves first traversal order" do
    edges = [
      %{from_node: "a", to_node: "b"},
      %{from_node: "b", to_node: "a"},
      %{from_node: "a", to_node: "c"}
    ]

    assert JobTopology.downstream_index(edges) == %{
             "a" => ["b", "a", "c"],
             "b" => ["a", "b", "c"]
           }

    assert JobTopology.downstream_index([]) == %{}
  end
end
