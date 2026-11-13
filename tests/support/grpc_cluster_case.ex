defmodule MirrorNeuron.GrpcClusterCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.GrpcClusterCase
    end
  end

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

  def restore_env(key, nil) when is_atom(key), do: Application.delete_env(:mirror_neuron, key)

  def restore_env(key, value) when is_atom(key),
    do: Application.put_env(:mirror_neuron, key, value)

  def restore_env(name, nil), do: System.delete_env(name)
  def restore_env(name, value), do: System.put_env(name, value)

  def identity_stream(token), do: %{headers: %{"authorization" => "Bearer #{token}"}}

  def restore_system_env(key, nil), do: System.delete_env(key)
  def restore_system_env(key, value), do: System.put_env(key, value)

  def write_token_file(prefix, token) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.write!(path, token <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  def redis_available? do
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

  def cleanup_namespace(namespace) do
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

  def start_tcp_server do
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
