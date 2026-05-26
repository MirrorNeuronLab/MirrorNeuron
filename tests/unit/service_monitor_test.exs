defmodule MirrorNeuron.ServiceMonitorTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ServiceMonitor

  test "refreshable_on_current_node? skips services owned by another runtime node" do
    assert ServiceMonitor.refreshable_on_current_node?(%{"id" => "global-service"})

    assert ServiceMonitor.refreshable_on_current_node?(%{
             "id" => "local-service",
             "node" => to_string(Node.self())
           })

    refute ServiceMonitor.refreshable_on_current_node?(%{
             "id" => "remote-service",
             "node" => "mirror_neuron@192.0.2.10"
           })
  end
end
