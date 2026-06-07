defmodule MirrorNeuron.Grpc.JobServerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.ClusterServer
  alias MirrorNeuron.Grpc.JobServer
  alias MirrorNeuron.Cluster.NodeState

  alias Mirrorneuron.Cluster.V1.{
    CheckServicesRequest,
    DrainNodeRequest,
    NetworkHandshakeRequest,
    SetNodeMaintenanceRequest
  }

  alias Mirrorneuron.Job.V1.{
    ClearJobsRequest,
    ClearJobsResponse,
    GetDeploymentRequest,
    ListDeploymentsRequest,
    SubmitJobRequest
  }

  @admin_token_env "MN_GRPC_ADMIN_TOKEN"
  @admin_token_file_env "MN_GRPC_ADMIN_TOKEN_FILE"
  @legacy_admin_token_env "MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN"
  @operator_token_env "MN_GRPC_AUTH_TOKEN"
  @operator_token_file_env "MN_GRPC_AUTH_TOKEN_FILE"

  setup do
    old_token = System.get_env(@admin_token_env)
    old_token_file = System.get_env(@admin_token_file_env)
    old_legacy_token = System.get_env(@legacy_admin_token_env)
    old_operator_token = System.get_env(@operator_token_env)
    old_operator_token_file = System.get_env(@operator_token_file_env)
    old_network_only = System.get_env("MN_NETWORK_ONLY")
    old_network_token = System.get_env("MN_NETWORK_JOIN_TOKEN")
    old_advertise_host = System.get_env("MN_NETWORK_ADVERTISE_HOST")
    old_redis_host = System.get_env("MN_NETWORK_REDIS_HOST")
    old_redis_port = System.get_env("MN_NETWORK_REDIS_PORT")
    old_redis_url = System.get_env("MN_REDIS_URL")
    old_grpc_port = System.get_env("MN_GRPC_PORT")
    old_dist_port = System.get_env("MN_DIST_PORT")
    old_cluster_nodes = System.get_env("MN_CLUSTER_NODES")
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    namespace = "mirror_neuron_grpc_job_server_test_#{System.unique_integer([:positive])}"

    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_REDIS_NAMESPACE", namespace)

    System.delete_env(@admin_token_env)
    System.delete_env(@admin_token_file_env)
    System.delete_env(@legacy_admin_token_env)
    System.delete_env(@operator_token_file_env)
    System.delete_env("MN_NETWORK_ONLY")
    System.delete_env("MN_NETWORK_JOIN_TOKEN")
    System.delete_env("MN_REDIS_URL")

    on_exit(fn ->
      cleanup_namespace(namespace)
      restore_env(:redis_namespace, old_namespace)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_env(@admin_token_env, old_token)
      restore_env(@admin_token_file_env, old_token_file)
      restore_env(@legacy_admin_token_env, old_legacy_token)
      restore_env(@operator_token_env, old_operator_token)
      restore_env(@operator_token_file_env, old_operator_token_file)
      restore_env("MN_NETWORK_ONLY", old_network_only)
      restore_env("MN_NETWORK_JOIN_TOKEN", old_network_token)
      restore_env("MN_NETWORK_ADVERTISE_HOST", old_advertise_host)
      restore_env("MN_NETWORK_REDIS_HOST", old_redis_host)
      restore_env("MN_NETWORK_REDIS_PORT", old_redis_port)
      restore_env("MN_REDIS_URL", old_redis_url)
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

  test "clear_jobs accepts admin token from token file before stale env token" do
    token_file = write_token_file("mn-admin-token", "file-admin-token")
    System.put_env(@admin_token_env, "stale-admin-token")
    System.put_env(@admin_token_file_env, token_file)

    try do
      response = JobServer.clear_jobs(%ClearJobsRequest{admin_token: "file-admin-token"}, nil)

      assert %ClearJobsResponse{} = response
      assert is_integer(response.cleared_count)
    rescue
      error in GRPC.RPCError ->
        refute Exception.message(error) =~ "ClearJobs requires #{@admin_token_env}"
    end
  end

  test "clear_jobs rejects stale env token when token file is authoritative" do
    token_file = write_token_file("mn-admin-token", "file-admin-token")
    System.put_env(@admin_token_env, "stale-admin-token")
    System.put_env(@admin_token_file_env, token_file)

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.clear_jobs(%ClearJobsRequest{admin_token: "stale-admin-token"}, nil)
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

  test "network-only mode rejects deployment RPCs" do
    System.put_env("MN_NETWORK_ONLY", "true")

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.get_deployment(%GetDeploymentRequest{id_or_key: "agent-api"}, nil)
      end

    assert Exception.message(error) =~ "GetDeployment is disabled"
  end

  test "deployment status RPCs return JSON-safe results" do
    deployment_id = "dep-grpc-#{System.unique_integer([:positive])}"

    assert {:ok, _deployment} =
             MirrorNeuron.Persistence.RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => "grpc-deploy",
               "status" => "successful",
               "current_version" => "1"
             })

    response = JobServer.get_deployment(%GetDeploymentRequest{id_or_key: "grpc-deploy"}, nil)
    assert %{"deployment_key" => "grpc-deploy"} = Jason.decode!(response.result_json)

    list_response = JobServer.list_deployments(%ListDeploymentsRequest{query_json: "{}"}, nil)
    assert %{"data" => deployments} = Jason.decode!(list_response.result_json)
    assert Enum.any?(deployments, &(&1["deployment_key"] == "grpc-deploy"))
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
    System.put_env(@operator_token_env, "primary-auth-token")
    System.put_env(@admin_token_env, "primary-admin-token")

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
    assert response.grpc_auth_token == "primary-auth-token"
    assert response.grpc_admin_token == "primary-admin-token"

    node_info = Jason.decode!(response.node_info_json)
    assert node_info["node_name"] == to_string(Node.self())
    assert is_binary(node_info["display_name"])
    assert is_integer(node_info["gpu_count"])
  end

  test "network handshake returns file-backed grpc tokens before stale env tokens" do
    auth_file = write_token_file("mn-auth-token", "file-auth-token")
    admin_file = write_token_file("mn-admin-token", "file-admin-token")

    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env(@operator_token_env, "stale-auth-token")
    System.put_env(@operator_token_file_env, auth_file)
    System.put_env(@admin_token_env, "stale-admin-token")
    System.put_env(@admin_token_file_env, admin_file)

    response =
      ClusterServer.network_handshake(%NetworkHandshakeRequest{token: "join-secret"}, nil)

    assert response.grpc_auth_token == "file-auth-token"
    assert response.grpc_admin_token == "file-admin-token"
  end

  test "network-only handshake does not record joining node metadata" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    joining_node = "mirror_neuron@10.0.0.90"

    _response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          token: "join-secret",
          node_name: joining_node,
          node_info_json: Jason.encode!(%{"address" => "10.0.0.90"})
        },
        nil
      )

    assert {:error, _reason} = NodeState.fetch(joining_node)
  end

  test "network handshake records joining node metadata for scheduling" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    joining_node = "mirror_neuron@10.0.0.42"

    node_info = %{
      "node_name" => joining_node,
      "display_name" => "spark gb10",
      "address" => "10.0.0.42",
      "grpc_host" => "10.0.0.42",
      "node_role" => "runtime",
      "capabilities" => ["cuda", "nvidia", "nvidia-gb10"],
      "gpu_count" => 1,
      "hardware" => %{
        "gpu" => %{
          "vendor" => "NVIDIA",
          "model" => "NVIDIA GB10",
          "count" => 1,
          "memory_gb" => 128,
          "memory_source" => "shared_system_memory"
        }
      }
    }

    _response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          token: "join-secret",
          node_name: joining_node,
          node_info_json: Jason.encode!(node_info)
        },
        nil
      )

    assert {:ok, state} = NodeState.fetch(joining_node)
    assert state["status"] == "joining"
    assert state["operator_disconnect"] == false
    assert state["scheduling_eligible"] == true
    assert state["display_name"] == "spark gb10"
    assert state["address"] == "10.0.0.42"
    assert state["grpc_host"] == "10.0.0.42"
    assert state["node_role"] == "runtime"
    assert state["capabilities"] == ["cuda", "nvidia", "nvidia-gb10"]
    assert state["gpu_count"] == 1
    assert get_in(state, ["hardware", "gpu", "model"]) == "NVIDIA GB10"
    assert get_in(state, ["hardware", "gpu", "memory_gb"]) == 128
    assert get_in(state, ["hardware", "gpu", "memory_source"]) == "shared_system_memory"
    assert NodeState.schedulable?(joining_node)
  end

  test "network handshake clears operator disconnect when a node rejoins with a new address" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    node_name = "mirror_neuron@10.0.0.42"

    assert {:ok, _state} =
             NodeState.mark(node_name, "disconnected", %{
               "operator_disconnect" => true,
               "scheduling_eligible" => false,
               "address" => "10.0.0.20",
               "grpc_host" => "10.0.0.20",
               "capabilities" => ["cpu"]
             })

    _response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          token: "join-secret",
          node_name: node_name,
          node_info_json:
            Jason.encode!(%{
              "address" => "10.0.0.84",
              "grpc_host" => "10.0.0.84",
              "node_role" => "runtime",
              "capabilities" => ["cuda", "nvidia-gb10"],
              "gpu_count" => 1
            })
        },
        nil
      )

    assert {:ok, state} = NodeState.fetch(node_name)
    assert state["status"] == "joining"
    assert state["operator_disconnect"] == false
    assert state["scheduling_eligible"] == true
    assert state["address"] == "10.0.0.84"
    assert state["grpc_host"] == "10.0.0.84"
    assert state["capabilities"] == ["cuda", "nvidia-gb10"]
    assert state["gpu_count"] == 1
    assert NodeState.schedulable?(node_name)
  end

  test "network handshake refreshes cordoned node metadata without making it schedulable" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    for status <- ["maintenance", "draining"] do
      node_name = "mirror_neuron_#{status}@10.0.0.42"

      assert {:ok, _state} =
               NodeState.mark(node_name, status, %{
                 "scheduling_eligible" => false,
                 "address" => "10.0.0.20",
                 "grpc_host" => "10.0.0.20",
                 "capabilities" => ["cpu"]
               })

      _response =
        ClusterServer.network_handshake(
          %NetworkHandshakeRequest{
            token: "join-secret",
            node_name: node_name,
            node_info_json:
              Jason.encode!(%{
                "address" => "10.0.0.84",
                "grpc_host" => "10.0.0.84",
                "node_role" => "runtime",
                "capabilities" => ["cuda", "nvidia-gb10"],
                "gpu_count" => 1
              })
          },
          nil
        )

      assert {:ok, state} = NodeState.fetch(node_name)
      assert state["status"] == status
      assert state["operator_disconnect"] == false
      assert state["address"] == "10.0.0.84"
      assert state["grpc_host"] == "10.0.0.84"
      assert state["capabilities"] == ["cuda", "nvidia-gb10"]
      assert state["gpu_count"] == 1
      refute NodeState.schedulable?(node_name)
    end
  end

  test "network handshake rejects a missing or wrong join token" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.network_handshake(%NetworkHandshakeRequest{token: "wrong"}, nil)
      end

    assert Exception.message(error) =~ "valid MN_NETWORK_JOIN_TOKEN is required"
  end

  test "cluster peer helpers tolerate absent peer links" do
    assert :ok = ClusterServer.connect_peer("mirror_neuron@10.0.0.99")

    assert :ok = ClusterServer.disconnect_peer("mirror_neuron@10.0.0.99")

    assert :ok =
             ClusterServer.disconnect_peers([
               "mirror_neuron@10.0.0.98",
               "mirror_neuron@10.0.0.97",
               ""
             ])
  end

  test "check services RPC runs generic direct checks and returns a validation report" do
    System.put_env(@operator_token_env, "operator-token")
    port = start_tcp_server()

    response =
      ClusterServer.check_services(
        %CheckServicesRequest{
          services_json:
            Jason.encode!([
              %{
                "name" => "agent-api",
                "address" => "127.0.0.1",
                "port" => port,
                "checks" => [%{"name" => "tcp", "type" => "tcp", "timeout_ms" => 1_000}]
              }
            ])
        },
        %{headers: %{"authorization" => "Bearer operator-token"}}
      )

    assert %{"ok" => true, "results" => [%{"name" => "agent-api"}]} =
             Jason.decode!(response.result_json)
  end

  defp restore_env(key, nil) when is_atom(key), do: Application.delete_env(:mirror_neuron, key)

  defp restore_env(key, value) when is_atom(key),
    do: Application.put_env(:mirror_neuron, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp write_token_file(prefix, token) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.write!(path, token <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
        :ok

      _ ->
        :ok
    end
  end

  defp start_tcp_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listen_socket)

    spawn_link(fn ->
      with {:ok, socket} <- :gen_tcp.accept(listen_socket, 5_000) do
        :gen_tcp.close(socket)
      end

      :gen_tcp.close(listen_socket)
    end)

    port
  end
end
