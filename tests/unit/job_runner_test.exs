defmodule MirrorNeuron.Runtime.JobRunnerTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.JobRunner

  test "child spec carries preferred start node for Horde placement" do
    spec =
      JobRunner.child_spec(
        {"job-1", :manifest, [preferred_start_node: "mirror_neuron@127.0.0.1"]}
      )

    assert spec.mirror_neuron_target_node == "mirror_neuron@127.0.0.1"
  end

  test "child spec omits target node when no preferred start node is set" do
    spec = JobRunner.child_spec({"job-1", :manifest, []})

    refute Map.has_key?(spec, :mirror_neuron_target_node)
  end
end
