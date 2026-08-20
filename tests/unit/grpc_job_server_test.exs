defmodule MirrorNeuron.Grpc.JobServerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.ClusterServer
  alias MirrorNeuron.Cluster.JoinClaim
  alias MirrorNeuron.Cluster.NodeState

  alias Mirrorneuron.Cluster.V1.{
    AddNodeRequest,
    CheckServicesRequest,
    NetworkHandshakeRequest,
    RemoveNodeRequest,
    SetResourceRequest
  }

  @identity_token_env "MN_GRPC_AUTH_TOKEN"
  @identity_token_file_env "MN_GRPC_AUTH_TOKEN_FILE"
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

    def persist_node_runtime_status(node_name, domain, snapshot) do
      existing =
        case fetch_node_state(node_name) do
          {:ok, state} -> state
          _ -> %{}
        end

      runtime_status = Map.get(existing, "runtime_status", %{})

      persist_node_state(
        node_name,
        Map.put(existing, "runtime_status", Map.put(runtime_status, domain, snapshot))
      )
    end

    def read_node_runtime_status_events(_node_name, _count) do
      {:ok,
       [
         %{
           "id" => "1-0",
           "node" => "mirror_neuron@spark",
           "domain" => "models",
           "revision" => "spark-v1"
         },
         %{
           "id" => "1-1",
           "node" => "mirror_neuron@test",
           "domain" => "models",
           "revision" => "local-v1"
         },
         %{
           "id" => "1-2",
           "node" => "mirror_neuron@spark",
           "domain" => "jobs",
           "revision" => "jobs-v1"
         }
       ]}
    end

    def ack_node_runtime_status_events(_node_name, event_ids) do
      notify({:runtime_status_events_acked, event_ids})
      {:ok, length(Enum.uniq(event_ids))}
    end

    def runtime_status_snapshots(_domains) do
      {:ok,
       %{
         "jobs" => %{"revision" => "jobs-v1", "status" => %{"count" => 0, "records" => []}},
         "schedules" => %{
           "revision" => "schedules-v1",
           "status" => %{"count" => 1, "records" => [%{"schedule_id" => "nightly"}]}
         },
         "deployments" => %{
           "revision" => "deployments-v1",
           "status" => %{"count" => 0, "records" => []}
         }
       }}
    end

    def read_node_cluster_runtime_status_events(_node_name, _count) do
      {:ok,
       [
         %{
           "id" => "2-0",
           "node" => "mirror_neuron@spark",
           "domain" => "schedules",
           "entity_id" => "nightly",
           "action" => "upsert",
           "revision" => "schedules-v1"
         },
         %{
           "id" => "2-1",
           "node" => "mirror_neuron@test",
           "domain" => "deployments",
           "entity_id" => "local-deployment",
           "action" => "upsert",
           "revision" => "local-deployment-v1"
         }
       ]}
    end

    def ack_node_cluster_runtime_status_events(_node_name, event_ids) do
      notify({:cluster_runtime_status_events_acked, event_ids})
      {:ok, length(Enum.uniq(event_ids))}
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

  defmodule ServiceRegistryStub do
    @test_pid_name :grpc_job_server_test_pid

    def register_many(services) do
      notify({:services_registered, services})
      {:ok, services}
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

    old_identity_token = System.get_env(@identity_token_env)
    old_identity_token_file = System.get_env(@identity_token_file_env)
    old_network_only = System.get_env("MN_NETWORK_ONLY")
    old_network_token = System.get_env("MN_NETWORK_JOIN_TOKEN")
    old_mn_home = System.get_env("MN_HOME")
    old_advertise_host = System.get_env("MN_NETWORK_ADVERTISE_HOST")
    old_redis_host = System.get_env("MN_NETWORK_REDIS_HOST")
    old_redis_port = System.get_env("MN_NETWORK_REDIS_PORT")
    old_redis_url = System.get_env("MN_REDIS_URL")
    old_redis_ha_mode = System.get_env("MN_REDIS_HA_MODE")
    old_redis_sentinels = System.get_env("MN_REDIS_SENTINELS")
    old_redis_sentinel_master = System.get_env("MN_REDIS_SENTINEL_MASTER")
    old_redis_wait_replicas = System.get_env("MN_REDIS_WAIT_REPLICAS")
    old_redis_wait_timeout_ms = System.get_env("MN_REDIS_WAIT_TIMEOUT_MS")
    old_grpc_port = System.get_env("MN_GRPC_PORT")
    old_dist_port = System.get_env("MN_DIST_PORT")
    old_cluster_nodes = System.get_env("MN_CLUSTER_NODES")
    old_node_runtime_models = System.get_env("MN_NODE_RUNTIME_MODELS")
    old_host_shared_storage_root = System.get_env("MN_HOST_SHARED_STORAGE_ROOT")
    old_runtime_shared_storage_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    old_reconnect_attempts = System.get_env("MN_REDIS_RECONNECT_ATTEMPTS")
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)

    old_application_reconnect_attempts =
      Application.get_env(:mirror_neuron, :redis_reconnect_attempts)

    old_cluster_node_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)
    old_node_state_store = Application.get_env(:mirror_neuron, :node_state_store)
    old_service_registry = Application.get_env(:mirror_neuron, :service_registry)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    namespace = "mirror_neuron_grpc_job_server_test_#{System.unique_integer([:positive])}"
    mn_home = Path.join(System.tmp_dir!(), "mn-home-#{System.unique_integer([:positive])}")

    ClusterNodeAdapterStub.reset()
    NodeStateStoreStub.reset()
    Application.put_env(:mirror_neuron, :cluster_node_adapter, ClusterNodeAdapterStub)
    Application.put_env(:mirror_neuron, :node_state_store, NodeStateStoreStub)
    Application.put_env(:mirror_neuron, :service_registry, ServiceRegistryStub)
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    Application.put_env(:mirror_neuron, :redis_reconnect_attempts, 0)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    System.put_env("MN_REDIS_RECONNECT_ATTEMPTS", "0")
    System.put_env("MN_HOME", mn_home)

    System.delete_env(@identity_token_env)
    System.delete_env(@identity_token_file_env)
    System.delete_env("MN_NETWORK_ONLY")
    System.delete_env("MN_NETWORK_JOIN_TOKEN")
    System.delete_env("MN_REDIS_URL")
    System.delete_env("MN_REDIS_HA_MODE")
    System.delete_env("MN_REDIS_SENTINELS")
    System.delete_env("MN_REDIS_SENTINEL_MASTER")
    System.delete_env("MN_REDIS_WAIT_REPLICAS")
    System.delete_env("MN_REDIS_WAIT_TIMEOUT_MS")
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
      restore_env(:service_registry, old_service_registry)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_env(@identity_token_env, old_identity_token)
      restore_env(@identity_token_file_env, old_identity_token_file)
      restore_env("MN_NETWORK_ONLY", old_network_only)
      restore_env("MN_NETWORK_JOIN_TOKEN", old_network_token)
      restore_env("MN_HOME", old_mn_home)
      restore_env("MN_NETWORK_ADVERTISE_HOST", old_advertise_host)
      restore_env("MN_NETWORK_REDIS_HOST", old_redis_host)
      restore_env("MN_NETWORK_REDIS_PORT", old_redis_port)
      restore_env("MN_REDIS_URL", old_redis_url)
      restore_env("MN_REDIS_HA_MODE", old_redis_ha_mode)
      restore_env("MN_REDIS_SENTINELS", old_redis_sentinels)
      restore_env("MN_REDIS_SENTINEL_MASTER", old_redis_sentinel_master)
      restore_env("MN_REDIS_WAIT_REPLICAS", old_redis_wait_replicas)
      restore_env("MN_REDIS_WAIT_TIMEOUT_MS", old_redis_wait_timeout_ms)
      restore_env("MN_GRPC_PORT", old_grpc_port)
      restore_env("MN_DIST_PORT", old_dist_port)
      restore_env("MN_CLUSTER_NODES", old_cluster_nodes)
      restore_env("MN_NODE_RUNTIME_MODELS", old_node_runtime_models)
      restore_env("MN_HOST_SHARED_STORAGE_ROOT", old_host_shared_storage_root)
      restore_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_runtime_shared_storage_root)
      restore_env("MN_REDIS_RECONNECT_ATTEMPTS", old_reconnect_attempts)
      File.rm_rf(mn_home)
    end)

    {:ok, redis_url: old_redis_url || "redis://localhost:6379/0"}
  end

  test "network-only mode forwards runtime model preparation to node-local SDK" do
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "mn-native-sdk-grpc:55052")
    parent = self()
    self_node = to_string(Node.self())

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn target, request, timeout ->
        send(
          parent,
          {:native_prepare_forwarded, target, Jason.decode!(request.resource_json), timeout}
        )

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json:
             Jason.encode!(%{
               "status" => "installed",
               "endpoint" => %{
                 "api_base" => "http://host.docker.internal:12434/engines/v1",
                 "node" => "mirror_neuron@test",
                 "source" => "sdk_native_runtime_service"
               }
             }),
           version: 1
         }}
      end)

      response =
        ClusterServer.prepare_runtime_model(
          %SetResourceRequest{
            resource_json:
              Jason.encode!(%{
                "node" => self_node,
                "model" => "nemotron3",
                "backend" => "llama.cpp",
                "source" => "mn-python-sdk"
              })
          },
          nil
        )

      assert %Mirrorneuron.Cluster.V1.SetResourceResponse{} = response

      assert %{"status" => "installed", "endpoint" => %{"source" => "sdk_native_runtime_service"}} =
               Jason.decode!(response.resource_json)

      assert_receive {:native_prepare_forwarded, "mn-native-sdk-grpc:55052",
                      %{
                        "node" => ^self_node,
                        "model" => "nemotron3",
                        "backend" => "llama.cpp",
                        "source" => "mn-python-sdk"
                      }, _timeout}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target)
      restore_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "prepare runtime model command forwards normalized default payload" do
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "mn-native-sdk-grpc:55052")
    parent = self()

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn target, request, timeout ->
        send(
          parent,
          {:native_prepare_forwarded, target, Jason.decode!(request.resource_json), timeout}
        )

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{"status" => "installed"}),
           version: 1
         }}
      end)

      response =
        ClusterServer.prepare_runtime_model(
          %SetResourceRequest{
            resource_json: Jason.encode!(%{"purpose" => "knowledge_rag"})
          },
          nil
        )

      assert %Mirrorneuron.Cluster.V1.SetResourceResponse{} = response
      assert %{"status" => "installed"} = Jason.decode!(response.resource_json)

      assert_receive {:native_prepare_forwarded, "mn-native-sdk-grpc:55052",
                      %{
                        "purpose" => "knowledge_rag",
                        "model" =>
                          "huggingface.co/jinaai/jina-embeddings-v5-text-small-retrieval:Q4_K_M",
                        "runtime_model" =>
                          "huggingface.co/jinaai/jina-embeddings-v5-text-small-retrieval:Q4_K_M"
                      }, _timeout}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target)
      restore_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "publish runtime status acknowledges the Redis-backed node snapshot" do
    System.put_env(@identity_token_env, "runtime-status-test")

    response =
      ClusterServer.publish_runtime_status(
        %SetResourceRequest{
          resource_json:
            Jason.encode!(%{
              "domain" => "models",
              "revision" => "models-v1",
              "status" => %{
                "models" => [%{"id" => "nemotron3", "installed" => true}]
              }
            })
        },
        identity_stream("runtime-status-test")
      )

    assert %{
             "domain" => "models",
             "revision" => "models-v1",
             "status" => "accepted"
           } = Jason.decode!(response.resource_json)

    self_node = ClusterNodeAdapterStub.self() |> to_string()
    assert {:ok, state} = NodeState.fetch(self_node)

    assert get_in(state, ["runtime_status", "models", "status", "models"]) == [
             %{"id" => "nemotron3", "installed" => true}
           ]
  end

  test "get runtime statuses reads shared snapshots without probing peer nodes" do
    System.put_env(@identity_token_env, "runtime-status-test")
    remote_node = "mirror_neuron@spark"

    assert {:ok, _state} =
             NodeState.mark(remote_node, "healthy", %{
               "grpc_host" => "192.168.4.173",
               "runtime_status" => %{
                 "models" => %{
                   "revision" => "spark-v1",
                   "status" => %{"models" => [%{"id" => "nemotron3"}]}
                 }
               }
             })

    response =
      ClusterServer.get_runtime_statuses(
        %Mirrorneuron.Cluster.V1.GetResourceRequest{},
        identity_stream("runtime-status-test")
      )

    assert %{
             "nodes" => nodes,
             "events" => [event],
             "cluster_status" => cluster_status,
             "cluster_events" => [cluster_event],
             "cluster_event_ack" => %{"acked_count" => 2}
           } = Jason.decode!(response.resource_json)

    assert event["id"] == "1-0"
    assert cluster_event["domain"] == "schedules"

    assert get_in(cluster_status, ["schedules", "status", "records"]) == [
             %{"schedule_id" => "nightly"}
           ]

    assert_receive {:runtime_status_events_acked, ["1-1", "1-2"]}
    assert_receive {:cluster_runtime_status_events_acked, ["2-0", "2-1"]}
    spark = Enum.find(nodes, &(&1["name"] == remote_node))
    assert spark["grpc_host"] == "192.168.4.173"
    assert get_in(spark, ["runtime_status", "models", "revision"]) == "spark-v1"
    refute_receive {:rpc_call, _, _, _, _}
  end

  test "ack runtime status events acknowledges the local Redis Stream consumer group" do
    System.put_env(@identity_token_env, "runtime-status-test")

    response =
      ClusterServer.ack_runtime_status_events(
        %SetResourceRequest{
          resource_json: Jason.encode!(%{"event_ids" => ["1-0", "2-0", "1-0"]})
        },
        identity_stream("runtime-status-test")
      )

    assert %{
             "status" => "acked",
             "event_ids" => ["1-0", "2-0"],
             "acked_count" => 2
           } = Jason.decode!(response.resource_json)

    assert_receive {:runtime_status_events_acked, ["1-0", "2-0"]}
  end

  test "prepare runtime model command preserves native model preconditions" do
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "mn-native-sdk-grpc:55052")

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn _target,
                                                                      _request,
                                                                      _timeout ->
        {:error,
         GRPC.RPCError.exception(
           :failed_precondition,
           "nemotron3 requires at least 48GB unified memory on Apple Silicon."
         )}
      end)

      error =
        assert_raise GRPC.RPCError, fn ->
          ClusterServer.prepare_runtime_model(
            %SetResourceRequest{resource_json: Jason.encode!(%{"model" => "nemotron3"})},
            nil
          )
        end

      assert error.status == GRPC.Status.failed_precondition()
      assert error.message == "nemotron3 requires at least 48GB unified memory on Apple Silicon."
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target)
      restore_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "network handshake accepts the configured join token", %{redis_url: redis_url} do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env("MN_NETWORK_ADVERTISE_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_PORT", "6380")
    # Keep this pointed at the test Redis endpoint. The handshake reserves a
    # join claim and may reconnect its shared Redix client on a transient
    # failure, so a documentation-only hostname would make the test flaky.
    System.put_env("MN_REDIS_URL", redis_url)
    # The test Redis instance has no replica. Requiring one here makes the
    # join-claim write block and leaks that global setting into other tests.
    # Replica-wait validation is covered by Redis sentinel tests.
    System.put_env("MN_REDIS_WAIT_REPLICAS", "0")
    System.put_env("MN_REDIS_WAIT_TIMEOUT_MS", "1000")
    System.put_env("MN_GRPC_PORT", "50055")
    System.put_env("MN_DIST_PORT", "4500")
    System.put_env("MN_CLUSTER_NODES", "mirror_neuron@192.168.4.10")
    System.put_env("MN_NODE_RUNTIME_MODELS", "nemotron3")
    System.put_env("MN_HOST_SHARED_STORAGE_ROOT", "/mnt/mn-shared")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", "/root/.mn/shared")
    System.put_env(@identity_token_env, "primary-auth-token")

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          token: "join-secret",
          node_name: "mirror_neuron@192.168.4.20"
        },
        nil
      )

    assert response.network_only
    assert response.runtime_mode == "network_only"
    assert response.grpc_host == "192.168.4.10"
    assert response.grpc_port == 50_055
    assert response.dist_port == 4_500
    assert response.redis_host == "192.168.4.10"
    assert response.redis_port == 6_380
    assert response.redis_url == advertised_redis_url(redis_url, "192.168.4.10", 6380)
    assert response.cluster_nodes == "mirror_neuron@192.168.4.10"
    assert response.grpc_auth_token == "primary-auth-token"

    node_info = Jason.decode!(response.node_info_json)
    assert node_info["node_name"] == "mirror_neuron@test"
    assert node_info["host_shared_storage_root"] == "/mnt/mn-shared"
    assert node_info["runtime_shared_storage_root"] == "/root/.mn/shared"
    assert node_info["redis_ha"]["wait_replicas"] == 0
    assert node_info["redis_ha"]["wait_timeout_ms"] == 1000
    assert node_info["runtime_models"] == ["nemotron3"]
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
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          token: "join-secret",
          node_name: "mirror_neuron@192.168.4.20"
        },
        nil
      )

    assert response.redis_url == "redis://192.168.4.10:6380/0"
  end

  test "network handshake returns the direct identity token before the file token" do
    auth_file = write_token_file("mn-auth-token", "file-auth-token")

    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env(@identity_token_env, "stale-auth-token")
    System.put_env(@identity_token_file_env, auth_file)

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          token: "join-secret",
          node_name: "mirror_neuron@192.168.4.20"
        },
        nil
      )

    assert response.grpc_auth_token == "stale-auth-token"
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

  test "network-only handshake keeps worker claimed by the first master" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    owner_a = "mirror_neuron@10.0.0.11"
    owner_b = "mirror_neuron@10.0.0.12"

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{token: "join-secret", node_name: owner_a},
        nil
      )

    assert response.network_only
    assert {:ok, %{"state" => "pending", "owner_node" => ^owner_a}} = JoinClaim.read()

    retry =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{token: "join-secret", node_name: owner_a},
        nil
      )

    assert retry.network_only

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.network_handshake(
          %NetworkHandshakeRequest{token: "join-secret", node_name: owner_b},
          nil
        )
      end

    assert error.status == GRPC.Status.already_exists()
    assert Exception.message(error) =~ "already join a cluster"
  end

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
        %NetworkHandshakeRequest{token: "join-secret", node_name: new_owner},
        nil
      )

    assert response.network_only
    assert {:ok, %{"state" => "pending", "owner_node" => ^new_owner}} = JoinClaim.read()
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

    ClusterNodeAdapterStub.put_rpc_result(
      remote_node,
      ClusterServer,
      :node_advertisement_info,
      [],
      %{
        "runtime_models" => ["nemotron3"]
      }
    )

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

    assert_receive {:rpc_call, ^remote_node, ClusterServer, :confirm_join_claim,
                    ["mirror_neuron@test"], 2_000}

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

    assert_receive {:rpc_call, ^remote_node, MirrorNeuron.Cluster.Manager, :add_node,
                    ["mirror_neuron@test"], 5_000}

    assert_receive {:services_registered, services}
    assert [%{"name" => "docker-model-runner", "node" => ^node_name} = service] = services
    assert "model:nemotron3" in service["tags"]
    assert "model:ai/nemotron3:latest" in service["tags"]
  end

  test "add_node clears stale disconnected scheduling state when a worker rejoins" do
    node_name = "mirror_neuron@10.0.0.42"
    remote_node = String.to_atom(node_name)

    assert {:ok, _state} =
             NodeState.mark(node_name, "disconnected", %{
               "scheduling_eligible" => false,
               "reason" => "operator requested disconnect"
             })

    assert_receive {:node_state_persisted, ^node_name, %{"status" => "disconnected"}}

    response =
      ClusterServer.add_node(%AddNodeRequest{node_name: node_name, token: "join-secret"}, nil)

    assert response.node_name == node_name
    assert response.status == "connected"
    assert_receive {:connect, ^remote_node}
    assert_receive {:node_state_persisted, ^node_name, %{"status" => "healthy"} = state}
    assert state["operator_disconnect"] == false
    assert state["scheduling_eligible"] == true
    assert NodeState.schedulable?(node_name)
  end

  test "remove_node marks operator disconnect before clearing claim and disconnecting locally" do
    node_name = "mirror_neuron@10.0.0.42"
    remote_node = String.to_atom(node_name)

    response = ClusterServer.remove_node(%RemoveNodeRequest{node_name: node_name}, nil)

    assert response.node_name == node_name
    assert response.status == "disconnected"

    assert_receive {:node_state_persisted, ^node_name,
                    %{
                      "status" => "disconnected",
                      "operator_disconnect" => true,
                      "scheduling_eligible" => false
                    }}

    assert_receive {:rpc_call, ^remote_node, ClusterServer, :clear_join_claim,
                    ["mirror_neuron@test"], 2_000}

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
    System.put_env(@identity_token_env, "operator-token")
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

  defp identity_stream(token), do: %{headers: %{"authorization" => "Bearer #{token}"}}

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

  defp advertised_redis_url(redis_url, host, port) do
    uri = URI.parse(redis_url)
    scheme = uri.scheme || "redis"
    path = uri.path || "/0"
    userinfo = if uri.userinfo in [nil, ""], do: "", else: "#{uri.userinfo}@"

    "#{scheme}://#{userinfo}#{host}:#{port}#{path}"
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
