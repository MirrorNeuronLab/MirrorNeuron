defmodule MirrorNeuron.CLI.DependencyCheckTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.CLI.DependencyCheck

  test "identifies service startup commands" do
    assert DependencyCheck.service_command?(["server"])
    assert DependencyCheck.service_command?(["standalone-start"])
    assert DependencyCheck.service_command?(["cluster", "start"])
    assert DependencyCheck.service_command?(["cluster", "join", "--node-id", "n1"])

    refute DependencyCheck.service_command?(["run", "examples/research_flow"])
    refute DependencyCheck.service_command?(["validate", "examples/research_flow"])
    refute DependencyCheck.service_command?(["cluster", "status"])
  end
end
