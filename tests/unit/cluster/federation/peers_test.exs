defmodule MirrorNeuron.Cluster.FederationRegistryTest.PeersTest do
  use MirrorNeuron.FederationRegistryCase, async: false

  import Bitwise

  alias MirrorNeuron.Cluster.FederationRegistry
  alias MirrorNeuron.FederationRegistryCase.CoordinationStoreStub
  alias MirrorNeuron.FederationRegistryCase.NodeStateStoreStub

  test "registration is idempotent, private, and persistently unlocks a worker", %{home: home} do
    credential = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:ok, peer, "registered"} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), credential)

    refute Map.has_key?(peer, "peer_auth_token")
    assert peer["connection_mode"] == "federated"
    assert FederationRegistry.ready?()
    refute MirrorNeuron.Grpc.NetworkOnly.enabled?()

    path = Path.join([home, "federation", "peers.json"])
    assert band(File.stat!(path).mode, 0o777) == 0o600

    assert {:ok, _peer, "already_registered"} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), credential)

    conflicting = Map.put(peer_info(), "grpc_port", 55_099)

    assert {:ok, updated, "already_registered"} =
             FederationRegistry.register("mirror_neuron@peer", conflicting, credential)

    assert updated["grpc_port"] == 55_099
    assert length(FederationRegistry.list()) == 1

    assert {:error, :peer_identity_conflict} =
             FederationRegistry.register("mirror_neuron@peer", conflicting, "wrong-token")

    assert {:error, :peer_identity_conflict} =
             FederationRegistry.register(
               "mirror_neuron@peer",
               put_in(conflicting, ["coordination_store", "identity"], "different-store"),
               credential
             )
  end

  test "registration rejects shared coordination store identities" do
    shared = put_in(peer_info(), ["coordination_store", "identity"], "store-local")

    assert {:error, :shared_coordination_store} =
             FederationRegistry.register("mirror_neuron@peer", shared, "scoped")
  end

  test "peer refresh propagates released memory and admission through node and resource reports" do
    alias MirrorNeuron.Cluster.Manager
    alias MirrorNeuron.Execution.LeaseManager
    alias MirrorNeuron.Runtime.NodeAdmissionState

    unless Process.whereis(LeaseManager), do: start_supervised!(LeaseManager)
    previous_resource_store = Application.get_env(:mirror_neuron, :resource_limits_store)
    Application.put_env(:mirror_neuron, :resource_limits_store, CoordinationStoreStub)
    on_exit(fn -> restore_app_env(:resource_limits_store, previous_resource_store) end)

    {:ok, busy, _} =
      NodeAdmissionState.transition(NodeAdmissionState.new(), "submit", %{"run_id" => "research"})

    {:ok, busy, _} =
      NodeAdmissionState.transition(busy, "submit", %{"run_id" => "litigation"})

    for {state, available} <- [{busy, 31_014}, {NodeAdmissionState.new(), 119_240}] do
      admission =
        state
        |> Map.take(["holder", "queue", "generation", "legacy"])
        |> Map.put("capability", "exclusive_run_v1")

      device = %{
        "id" => "gpu-shared",
        "kind" => "gpu",
        "name" => "NVIDIA GB10",
        "memory_total_mb" => 124_607,
        "memory_free_mb" => available
      }

      hardware = %{
        "memory" => %{"total_mb" => 124_607, "available_mb" => available},
        "gpu" => [device],
        "devices" => [device]
      }

      assert {:ok, _, _} =
               FederationRegistry.register(
                 "mirror_neuron@peer",
                 Map.merge(peer_info(), %{"admission" => admission, "hardware" => hardware}),
                 "scoped"
               )

      assert {:ok, stored} = NodeStateStoreStub.fetch_node_state("mirror_neuron@peer")
      assert stored["admission"] == admission

      node = Enum.find(Manager.nodes(), &(&1.name == "mirror_neuron@peer"))
      assert node.admission == admission
      assert node.hardware == hardware
      refute node.scheduling_eligible
      assert node.job_owner_eligible

      resource =
        MirrorNeuron.Resource.list()["nodes"]
        |> Enum.find(&(&1["name"] == "mirror_neuron@peer"))

      assert resource["admission"] == admission
      assert resource["memory_available_gb"] == Float.round(available / 1024, 2)
      assert resource["gpu_memory_free_mb"] == available
    end
  end

  test "authenticated endpoint refresh retains job ownership and projections" do
    assert {:ok, _, _} = FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _, _} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-1", "status" => "running"}
             ])

    updated = Map.put(peer_info(), "grpc_host", "new-host.local")

    assert {:ok, _, "already_registered"} =
             FederationRegistry.register("mirror_neuron@peer", updated, "scoped")

    assert FederationRegistry.projection("job-1")["owner_node"] == "mirror_neuron@peer"
    assert length(FederationRegistry.list()) == 1

    assert {:error, :peer_identity_conflict} =
             FederationRegistry.register(
               "mirror_neuron@peer",
               Map.put(updated, "grpc_host", "attacker.local"),
               "wrong"
             )

    assert {:ok, saved} = FederationRegistry.fetch("mirror_neuron@peer")
    assert saved["grpc_host"] == "new-host.local"
  end
end
