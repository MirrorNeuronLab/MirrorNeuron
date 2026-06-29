defmodule MirrorNeuron.Grpc.JobServerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.ClusterServer
  alias MirrorNeuron.Grpc.JobServer
  alias MirrorNeuron.Cluster.NodeState

  alias Mirrorneuron.Cluster.V1.{
    AddNodeRequest,
    CheckServicesRequest,
    DrainNodeRequest,
    NetworkHandshakeRequest,
    RemoveNodeRequest,
    SetNodeMaintenanceRequest
  }

  alias Mirrorneuron.Job.V1.{
    CancelJobRequest,
    ClearJobsRequest,
    ClearJobsResponse,
    GetDeploymentRequest,
    ListDeploymentsRequest,
    SubmitJobRequest
  }

  @admin_token_env "MN_GRPC_ADMIN_TOKEN"
  @admin_token_file_env "MN_GRPC_ADMIN_TOKEN_FILE"
  @operator_token_env "MN_GRPC_AUTH_TOKEN"
  @operator_token_file_env "MN_GRPC_AUTH_TOKEN_FILE"
  @test_pid_name :grpc_job_server_test_pid

  defmodule NodeStateStoreStub do
    @test_pid_name :grpc_job_server_test_pid

    def reset do
      nodes()
      |> Enum.each(fn node_name -> :persistent_term.erase({__MODULE__, :state, node_name}) end)

      :persistent_term.put({__MODULE__, :nodes}, MapSet.new())
    end

    def persist_node_state(node_name, attrs) do
      state =
        attrs
        |> Map.put("node", node_name)
        |> Map.put_new("updated_at", "2026-06-11T00:00:00Z")

      nodes = MapSet.put(nodes(), node_name)
      :persistent_term.put({__MODULE__, :nodes}, nodes)
      :persistent_term.put({__MODULE__, :state, node_name}, state)
      notify({:node_state_persisted, node_name, state})

      {:ok, state}
    end

    def fetch_node_state(node_name) do
      case :persistent_term.get({__MODULE__, :state, node_name}, nil) do
        nil -> {:error, "node #{node_name} state was not found"}
        state -> {:ok, state}
      end
    end

    def list_node_states do
      states =
        nodes()
        |> Enum.map(fn node_name ->
          :persistent_term.get({__MODULE__, :state, node_name}, nil)
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, states}
    end

    defp nodes, do: :persistent_term.get({__MODULE__, :nodes}, MapSet.new())

    defp notify(message) do
      case Process.whereis(@test_pid_name) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  defmodule ClusterNodeAdapterStub do
    @test_pid_name :grpc_job_server_test_pid

    def reset do
      :persistent_term.put({__MODULE__, :self}, :mirror_neuron@test)
      :persistent_term.put({__MODULE__, :list}, [])
      :persistent_term.put({__MODULE__, :connect_results}, %{})
      :persistent_term.put({__MODULE__, :disconnect_results}, %{})
      :persistent_term.put({__MODULE__, :rpc_results}, %{})
    end

    def put_list(nodes), do: :persistent_term.put({__MODULE__, :list}, nodes)
    def put_connect_result(node, result), do: put_result(:connect_results, node, result)
    def put_disconnect_result(node, result), do: put_result(:disconnect_results, node, result)

    def put_rpc_result(node, module, function, args, result) do
      key = {node, module, function, args}
      results = :persistent_term.get({__MODULE__, :rpc_results}, %{})
      :persistent_term.put({__MODULE__, :rpc_results}, Map.put(results, key, result))
    end

    def self, do: :persistent_term.get({__MODULE__, :self}, :mirror_neuron@test)
    def list, do: :persistent_term.get({__MODULE__, :list}, [])

    def connect(node) do
      notify({:connect, node})
      Map.get(:persistent_term.get({__MODULE__, :connect_results}, %{}), node, true)
    end

    def disconnect(node) do
      notify({:disconnect, node})
      Map.get(:persistent_term.get({__MODULE__, :disconnect_results}, %{}), node, true)
    end

    def set_cookie(node, cookie) do
      notify({:set_cookie, node, cookie})
      :ok
    end

    def rpc_call(node, module, function, args, timeout) do
      notify({:rpc_call, node, module, function, args, timeout})

      :persistent_term.get({__MODULE__, :rpc_results}, %{})
      |> Map.get({node, module, function, args}, :ok)
    end

    defp put_result(key, node, result) do
      results = :persistent_term.get({__MODULE__, key}, %{})
      :persistent_term.put({__MODULE__, key}, Map.put(results, node, result))
    end

    defp notify(message) do
      case Process.whereis(@test_pid_name) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)

    old_token = System.get_env(@admin_token_env)
    old_token_file = System.get_env(@admin_token_file_env)
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
    old_host_shared_storage_root = System.get_env("MN_HOST_SHARED_STORAGE_ROOT")
    old_runtime_shared_storage_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    old_reconnect_attempts = System.get_env("MN_REDIS_RECONNECT_ATTEMPTS")
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)

    old_application_reconnect_attempts =
      Application.get_env(:mirror_neuron, :redis_reconnect_attempts)

    old_cluster_node_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)
    old_node_state_store = Application.get_env(:mirror_neuron, :node_state_store)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    namespace = "mirror_neuron_grpc_job_server_test_#{System.unique_integer([:positive])}"

    ClusterNodeAdapterStub.reset()
    NodeStateStoreStub.reset()
    Application.put_env(:mirror_neuron, :cluster_node_adapter, ClusterNodeAdapterStub)
    Application.put_env(:mirror_neuron, :node_state_store, NodeStateStoreStub)
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    Application.put_env(:mirror_neuron, :redis_reconnect_attempts, 0)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    System.put_env("MN_REDIS_RECONNECT_ATTEMPTS", "0")

    System.delete_env(@admin_token_env)
    System.delete_env(@admin_token_file_env)
    System.delete_env(@operator_token_env)
    System.delete_env(@operator_token_file_env)
    System.delete_env("MN_NETWORK_ONLY")
    System.delete_env("MN_NETWORK_JOIN_TOKEN")
    System.delete_env("MN_REDIS_URL")
    System.put_env("MN_HOST_SHARED_STORAGE_ROOT", "/tmp/mn-shared")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", "/root/.mn/shared")

    on_exit(fn ->
      if redis_available?(), do: cleanup_namespace(namespace)
      NodeStateStoreStub.reset()
      ClusterNodeAdapterStub.reset()
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      restore_env(:redis_namespace, old_namespace)
      restore_env(:redis_reconnect_attempts, old_application_reconnect_attempts)
      restore_env(:cluster_node_adapter, old_cluster_node_adapter)
      restore_env(:node_state_store, old_node_state_store)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_env(@admin_token_env, old_token)
      restore_env(@admin_token_file_env, old_token_file)
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
      restore_env("MN_HOST_SHARED_STORAGE_ROOT", old_host_shared_storage_root)
      restore_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_runtime_shared_storage_root)
      restore_env("MN_REDIS_RECONNECT_ATTEMPTS", old_reconnect_attempts)
    end)
  end

  test "clear_jobs rejects unauthenticated requests before deleting jobs" do
    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.clear_jobs(%ClearJobsRequest{}, nil)
      end

    assert Exception.message(error) =~ "ClearJobs requires #{@admin_token_env}"
  end

  test "clear_jobs accepts the configured admin token" do
    System.put_env(@admin_token_env, "configured-admin-token")

    try do
      response =
        JobServer.clear_jobs(%ClearJobsRequest{admin_token: "configured-admin-token"}, nil)

      assert %ClearJobsResponse{} = response
      assert is_integer(response.cleared_count)
    rescue
      error in GRPC.RPCError ->
        refute Exception.message(error) =~ "ClearJobs requires #{@admin_token_env}"
    end
  end

  test "clear_jobs rejects mismatched admin token" do
    System.put_env(@admin_token_env, "configured-admin-token")

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.clear_jobs(%ClearJobsRequest{admin_token: "wrong-admin-token"}, nil)
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

  test "cancel_job maps a missing runtime job to not_found" do
    job_id = "missing-grpc-job-#{System.unique_integer([:positive])}"

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.cancel_job(%CancelJobRequest{job_id: job_id}, nil)
      end

    assert error.status == GRPC.Status.not_found()
    assert Exception.message(error) =~ "not running" or Exception.message(error) =~ "not found"
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
    if redis_available?() do
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
    System.put_env("MN_REDIS_URL", "redis://:redis-secret@redis:6379/0")
    System.put_env("MN_GRPC_PORT", "50055")
    System.put_env("MN_DIST_PORT", "4500")
    System.put_env("MN_CLUSTER_NODES", "mirror_neuron@192.168.4.10")
    System.put_env("MN_HOST_SHARED_STORAGE_ROOT", "/mnt/mn-shared")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", "/root/.mn/shared")
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
    assert response.redis_url == "redis://:redis-secret@192.168.4.10:6380/0"
    assert response.cluster_nodes == "mirror_neuron@192.168.4.10"
    assert response.grpc_auth_token == "primary-auth-token"
    assert response.grpc_admin_token == "primary-admin-token"

    node_info = Jason.decode!(response.node_info_json)
    assert node_info["node_name"] == "mirror_neuron@test"
    assert node_info["host_shared_storage_root"] == "/mnt/mn-shared"
    assert node_info["runtime_shared_storage_root"] == "/root/.mn/shared"
    assert is_binary(node_info["display_name"])
    assert is_integer(node_info["gpu_count"])
  end

  test "network handshake preserves unauthenticated Redis URLs when configured without auth" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env("MN_NETWORK_ADVERTISE_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_PORT", "6380")
    System.put_env("MN_REDIS_URL", "redis://redis:6379/0")

    response =
      ClusterServer.network_handshake(%NetworkHandshakeRequest{token: "join-secret"}, nil)

    assert response.redis_url == "redis://192.168.4.10:6380/0"
  end

  test "network handshake returns direct grpc tokens before file tokens" do
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

    assert response.grpc_auth_token == "stale-auth-token"
    assert response.grpc_admin_token == "stale-admin-token"
  end

  test "network-only handshake connects back to joining peer without recording metadata" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    joining_node = "mirror_neuron@10.0.0.90"
    joining_atom = String.to_atom(joining_node)
    cookie = cookie_from_token("join-secret")

    _response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          token: "join-secret",
          node_name: joining_node,
          node_info_json: Jason.encode!(%{"address" => "10.0.0.90"})
        },
        nil
      )

    assert_receive {:set_cookie, ^joining_atom, cookie_atom}
    assert Atom.to_string(cookie_atom) == cookie
    assert_receive {:connect, ^joining_atom}
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

  test "add_node sets cookie, connects, and syncs peer cookies after successful join" do
    node_name = "mirror_neuron@10.0.0.42"
    remote_node = String.to_atom(node_name)
    peer_a = :"peer-a@lab"
    peer_b = :"peer-b@lab"
    cookie = cookie_from_token("join-secret")

    ClusterNodeAdapterStub.put_list([peer_a, remote_node, peer_b])

    response =
      ClusterServer.add_node(%AddNodeRequest{node_name: node_name, token: "join-secret"}, nil)

    assert response.node_name == node_name
    assert response.status == "connected"

    assert_receive {:set_cookie, ^remote_node, cookie_atom}
    assert Atom.to_string(cookie_atom) == cookie
    assert_receive {:connect, ^remote_node}
    assert_receive {:node_state_persisted, ^node_name, %{"status" => "healthy"} = state}
    assert state["operator_disconnect"] == false
    assert state["scheduling_eligible"] == true

    assert_receive {:rpc_call, ^peer_a, ClusterServer, :set_peer_cookie, [^node_name, ^cookie],
                    2_000}

    assert_receive {:rpc_call, ^remote_node, ClusterServer, :set_peer_cookie,
                    ["peer-a@lab", ^cookie], 2_000}

    assert_receive {:rpc_call, ^peer_b, ClusterServer, :set_peer_cookie, [^node_name, ^cookie],
                    2_000}

    assert_receive {:rpc_call, ^remote_node, ClusterServer, :set_peer_cookie,
                    ["peer-b@lab", ^cookie], 2_000}

    assert_receive {:rpc_call, ^remote_node, ClusterServer, :set_peer_cookie,
                    ["mirror_neuron@test", ^cookie], 2_000}

    assert_receive {:rpc_call, ^remote_node, ClusterServer, :connect_peer, ["mirror_neuron@test"],
                    2_000}
  end

  test "remove_node disconnects cluster peers before marking operator disconnect locally" do
    node_name = "mirror_neuron@10.0.0.42"
    remote_node = String.to_atom(node_name)
    peer_a = :"peer-a@lab"
    peer_b = :"peer-b@lab"

    ClusterNodeAdapterStub.put_list([remote_node, peer_a, peer_b])

    response = ClusterServer.remove_node(%RemoveNodeRequest{node_name: node_name}, nil)

    assert response.node_name == node_name
    assert response.status == "disconnected"

    assert_receive {:rpc_call, ^remote_node, ClusterServer, :disconnect_peers,
                    [["peer-a@lab", "peer-b@lab"]], 2_000}

    assert_receive {:rpc_call, ^peer_a, ClusterServer, :disconnect_peer, [^node_name], 2_000}
    assert_receive {:rpc_call, ^peer_b, ClusterServer, :disconnect_peer, [^node_name], 2_000}

    assert_receive {:node_state_persisted, ^node_name,
                    %{
                      "status" => "disconnected",
                      "operator_disconnect" => true,
                      "scheduling_eligible" => false
                    }}

    assert_receive {:disconnect, ^remote_node}
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

  defp redis_available? do
    case Process.whereis(MirrorNeuron.Redis.Connection) do
      nil ->
        false

      _pid ->
        case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
          {:ok, "PONG"} -> true
          _ -> false
        end
    end
  catch
    :exit, _reason -> false
  end

  defp cookie_from_token(token) do
    :crypto.hash(:sha256, "mirror-neuron:cookie:#{token}")
    |> Base.encode16(case: :lower)
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
