defmodule MirrorNeuron.Grpc.JobServerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.ClusterServer
  alias MirrorNeuron.Grpc.JobServer

  alias Mirrorneuron.Cluster.V1.{
    DrainNodeRequest,
    NetworkHandshakeRequest,
    SetNodeMaintenanceRequest
  }

  alias Mirrorneuron.Job.V1.{ClearJobsRequest, SubmitJobRequest}
  @admin_token_env "MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN"

  setup do
    old_token = System.get_env(@admin_token_env)
    old_network_only = System.get_env("MN_NETWORK_ONLY")
    old_network_token = System.get_env("MN_NETWORK_JOIN_TOKEN")
    old_advertise_host = System.get_env("MN_NETWORK_ADVERTISE_HOST")
    old_redis_host = System.get_env("MN_NETWORK_REDIS_HOST")
    old_redis_port = System.get_env("MN_NETWORK_REDIS_PORT")
    old_grpc_port = System.get_env("MN_GRPC_PORT")
    old_dist_port = System.get_env("MN_DIST_PORT")
    old_cluster_nodes = System.get_env("MN_CLUSTER_NODES")
    System.delete_env(@admin_token_env)
    System.delete_env("MN_NETWORK_ONLY")
    System.delete_env("MN_NETWORK_JOIN_TOKEN")

    on_exit(fn ->
      restore_env(@admin_token_env, old_token)
      restore_env("MN_NETWORK_ONLY", old_network_only)
      restore_env("MN_NETWORK_JOIN_TOKEN", old_network_token)
      restore_env("MN_NETWORK_ADVERTISE_HOST", old_advertise_host)
      restore_env("MN_NETWORK_REDIS_HOST", old_redis_host)
      restore_env("MN_NETWORK_REDIS_PORT", old_redis_port)
      restore_env("MN_GRPC_PORT", old_grpc_port)
      restore_env("MN_DIST_PORT", old_dist_port)
      restore_env("MN_CLUSTER_NODES", old_cluster_nodes)
    end)
  end

  test "clear_jobs rejects unauthenticated requests before deleting jobs" do
    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.clear_jobs(%ClearJobsRequest{}, nil)
      end

    assert Exception.message(error) =~ "ClearJobs requires #{@admin_token_env}"
  end

  test "network-only mode rejects job submission" do
    System.put_env("MN_NETWORK_ONLY", "true")

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.submit_job(%SubmitJobRequest{manifest_json: "{}"}, nil)
      end

    assert Exception.message(error) =~ "SubmitJob is disabled"
  end

  test "network-only mode rejects destructive admin RPCs before token checks" do
    System.put_env("MN_NETWORK_ONLY", "true")

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.clear_jobs(%ClearJobsRequest{}, nil)
      end

    assert Exception.message(error) =~ "ClearJobs is disabled"

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.drain_node(%DrainNodeRequest{node_name: "node@lab"}, nil)
      end

    assert Exception.message(error) =~ "DrainNode is disabled"

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.set_node_maintenance(
          %SetNodeMaintenanceRequest{node_name: "node@lab", enabled: true},
          nil
        )
      end

    assert Exception.message(error) =~ "SetNodeMaintenance is disabled"
  end

  test "network handshake accepts the configured join token" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env("MN_NETWORK_ADVERTISE_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_PORT", "6380")
    System.put_env("MN_GRPC_PORT", "50055")
    System.put_env("MN_DIST_PORT", "4500")
    System.put_env("MN_CLUSTER_NODES", "mirror_neuron@192.168.4.10")

    response =
      ClusterServer.network_handshake(%NetworkHandshakeRequest{token: "join-secret"}, nil)

    assert response.network_only
    assert response.runtime_mode == "network_only"
    assert response.grpc_host == "192.168.4.10"
    assert response.grpc_port == 50_055
    assert response.dist_port == 4_500
    assert response.redis_host == "192.168.4.10"
    assert response.redis_port == 6_380
    assert response.redis_url == "redis://192.168.4.10:6380/0"
    assert response.cluster_nodes == "mirror_neuron@192.168.4.10"
  end

  test "network handshake rejects a missing or wrong join token" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.network_handshake(%NetworkHandshakeRequest{token: "wrong"}, nil)
      end

    assert Exception.message(error) =~ "valid MN_NETWORK_JOIN_TOKEN is required"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
