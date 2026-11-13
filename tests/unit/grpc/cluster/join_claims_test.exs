defmodule MirrorNeuron.Grpc.ClusterServerTest.JoinClaimsTest do
  use MirrorNeuron.GrpcClusterCase, async: false

  alias MirrorNeuron.Grpc.ClusterServer
  alias MirrorNeuron.Cluster.JoinClaim
  alias Mirrorneuron.Cluster.V1.NetworkHandshakeRequest
  alias MirrorNeuron.GrpcClusterCase.ClusterNodeAdapterStub

  test "join claim confirm and clear helpers update worker-local ownership" do
    owner = "mirror_neuron@10.0.0.11"

    assert {:ok, %{"state" => "pending"}} = JoinClaim.reserve(owner)
    assert :ok = ClusterServer.confirm_join_claim(owner)
    assert {:ok, %{"state" => "confirmed", "owner_node" => ^owner} = claim} = JoinClaim.read()
    refute Map.has_key?(claim, "expires_at")

    ClusterNodeAdapterStub.put_list([String.to_atom(owner)])

    assert {:error, {:already_joined, ^owner}} =
             ClusterServer.confirm_join_claim("mirror_neuron@10.0.0.12")

    assert :ok = ClusterServer.clear_join_claim(owner)
    assert {:error, :missing} = JoinClaim.read()
  end

  test "confirmed join claim from disconnected owner is replaceable by explicit join" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    old_owner = "mirror_neuron@10.0.0.11"
    new_owner = "mirror_neuron@10.0.0.12"

    assert {:ok, %{"state" => "pending"}} = JoinClaim.reserve(old_owner)
    assert :ok = ClusterServer.confirm_join_claim(old_owner)
    assert {:ok, %{"state" => "confirmed", "owner_node" => ^old_owner}} = JoinClaim.read()

    ClusterNodeAdapterStub.put_list([])

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{version: 1, token: "join-secret", node_name: new_owner},
        nil
      )

    assert response.network_only
    assert {:ok, %{"state" => "pending", "owner_node" => ^new_owner}} = JoinClaim.read()
  end

  test "cluster peer helpers tolerate absent peer links" do
    assert :ok = ClusterServer.connect_peer("mirror_neuron@10.0.0.99")
    assert :ok = ClusterServer.connect_peer("")

    assert :ok = ClusterServer.disconnect_peer("mirror_neuron@10.0.0.99")
    assert :ok = ClusterServer.disconnect_peer("")

    assert :ok =
             ClusterServer.disconnect_peers([
               "mirror_neuron@10.0.0.98",
               "mirror_neuron@10.0.0.97",
               ""
             ])
  end
end
