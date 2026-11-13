defmodule MirrorNeuron.Cluster.FederationRegistryTest.AvailabilityTest do
  use MirrorNeuron.FederationRegistryCase, async: false

  alias MirrorNeuron.Cluster.FederationRegistry
  alias MirrorNeuron.FederationRegistryCase.NodeStateStoreStub

  test "offline projections remain readable and are marked stale" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _peer, _status} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-1", "status" => "running"}
             ])

    assert {:ok, _peer, _status} = FederationRegistry.mark_unavailable("mirror_neuron@peer")
    projection = FederationRegistry.projection("job-1")

    assert projection["owner_node"] == "mirror_neuron@peer"
    assert projection["owner_available"] == false
    assert projection["projection_level"] == "summary"
    assert projection["projection_stale"] == true

    path = Path.join([System.get_env("MN_HOME"), "federation", "peers.json"])
    refute File.read!(path) =~ "job-1"
  end

  test "a failed refresh stales projections without changing peer availability" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _peer, _status} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-1", "status" => "running"}
             ])

    assert :ok = FederationRegistry.mark_projections_stale("mirror_neuron@peer")
    assert {:ok, peer} = FederationRegistry.fetch("mirror_neuron@peer")
    assert peer["peer_available"] != false
    assert FederationRegistry.projection("job-1")["projection_stale"] == true
    assert FederationRegistry.projection("job-1")["owner_available"] == true
  end

  test "a successful probe restores peer health while cached summaries stay stale" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _peer, _status} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-1", "status" => "running"}
             ])

    assert {:ok, _, _} = FederationRegistry.mark_unavailable("mirror_neuron@peer")
    assert {:ok, _, _} = FederationRegistry.mark_available("mirror_neuron@peer")
    assert {:ok, state} = NodeStateStoreStub.fetch_node_state("mirror_neuron@peer")
    assert state["status"] == "healthy"
    assert state["peer_available"] == true
    assert FederationRegistry.projection("job-1")["owner_available"] == true
    assert FederationRegistry.projection("job-1")["projection_stale"] == true
  end
end
