defmodule MirrorNeuron.RedisStoreCase do
  use ExUnit.CaseTemplate
  import ExUnit.Assertions

  using do
    quote do
      import MirrorNeuron.RedisStoreCase
    end
  end

  defmodule CleanupNodeAdapterStub do
    import Kernel, except: [self: 0]

    def reset(test_pid) do
      :persistent_term.put({__MODULE__, :test_pid}, test_pid)
      :persistent_term.put({__MODULE__, :remote_result}, {:badrpc, :nodedown})
    end

    def self, do: :"cleanup-control@lab"
    def list, do: []
    def connect(_node), do: false
    def disconnect(_node), do: true
    def set_cookie(_node, _cookie), do: :ok

    def put_remote_result(result) do
      :persistent_term.put({__MODULE__, :remote_result}, result)
    end

    def rpc_call(node, module, function, args, timeout) do
      if test_pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(test_pid, {:cleanup_rpc, node, module, function, args, timeout})
      end

      if node == self() do
        :ok
      else
        :persistent_term.get({__MODULE__, :remote_result}, {:badrpc, :nodedown})
      end
    end
  end

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> raise "Redis must be running for redis store tests"
    end

    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_event_max_count = Application.get_env(:mirror_neuron, :event_max_count)
    old_terminal_ttl = Application.get_env(:mirror_neuron, :terminal_job_ttl_seconds)
    old_agent_snapshot_ttl = Application.get_env(:mirror_neuron, :agent_snapshot_ttl_seconds)
    old_bundle_archive_ttl = Application.get_env(:mirror_neuron, :bundle_archive_ttl_seconds)
    old_recovery_eval_ttl = Application.get_env(:mirror_neuron, :recovery_eval_ttl_seconds)
    old_system_recovery_eval_ttl = System.get_env("MN_RECOVERY_EVAL_TTL_SECONDS")
    old_wait_replicas = Application.get_env(:mirror_neuron, :redis_wait_replicas)
    old_wait_timeout = Application.get_env(:mirror_neuron, :redis_wait_timeout_ms)

    namespace = "mirror_neuron_test_#{System.unique_integer([:positive])}"
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    Application.put_env(:mirror_neuron, :redis_wait_replicas, 0)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 100)

    on_exit(fn ->
      cleanup_namespace(namespace)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_env(:redis_namespace, old_namespace)
      restore_env(:event_max_count, old_event_max_count)
      restore_env(:terminal_job_ttl_seconds, old_terminal_ttl)
      restore_env(:agent_snapshot_ttl_seconds, old_agent_snapshot_ttl)
      restore_env(:bundle_archive_ttl_seconds, old_bundle_archive_ttl)
      restore_env(:recovery_eval_ttl_seconds, old_recovery_eval_ttl)
      restore_system_env("MN_RECOVERY_EVAL_TTL_SECONDS", old_system_recovery_eval_ttl)
      restore_env(:redis_wait_replicas, old_wait_replicas)
      restore_env(:redis_wait_timeout_ms, old_wait_timeout)
    end)

    {:ok, namespace: namespace}
  end

  def restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  def restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  def restore_system_env(key, nil), do: System.delete_env(key)
  def restore_system_env(key, value), do: System.put_env(key, value)
  def redis_key(namespace, parts), do: Enum.join([namespace | parts], ":")

  def suspend_retention do
    suspend_process(MirrorNeuron.Persistence.Retention)
  end

  def suspend_background_schedule_sweeps do
    suspend_retention()
    suspend_process(MirrorNeuron.Cluster.Leader)
  end

  def suspend_process(name) do
    case Process.whereis(name) do
      process when is_pid(process) ->
        :sys.suspend(process)

        on_exit(fn ->
          if Process.alive?(process), do: :sys.resume(process)
        end)

      nil ->
        :ok
    end
  end

  def assert_service_instance_reclaimed(namespace, instance_id, service) do
    keys = [
      redis_key(namespace, ["service", "instances"]),
      redis_key(namespace, ["service", "name", service["name"]]),
      redis_key(namespace, ["service", "job", service["job_id"]]),
      redis_key(namespace, ["service", "agent", service["agent_id"]]),
      redis_key(namespace, ["service", "node", service["node"]])
    ]

    assert {:ok, nil} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["service", "instance", instance_id])
             ])

    for index_key <- keys do
      assert {:ok, 0} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SISMEMBER",
                 index_key,
                 instance_id
               ])
    end
  end

  def assert_deployment_membership(
        namespace,
        deployment_id,
        deployment_key,
        expected_membership,
        expected_current
      ) do
    assert {:ok, ^expected_membership} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployments"]),
               deployment_id
             ])

    assert {:ok, ^expected_membership} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployment", "key", deployment_key, "deployments"]),
               deployment_id
             ])

    assert {:ok, ^expected_current} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["deployment", "key", deployment_key, "current"])
             ])
  end

  def cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end

  def create_bundle(base_dir, graph_id) do
    bundle_dir = Path.join(base_dir, graph_id)
    payloads_dir = Path.join(bundle_dir, "payloads")

    File.mkdir_p!(payloads_dir)

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "flow" => %{
        "nodes" => [%{"node_id" => "node1", "agent_type" => "router", "role" => "root"}],
        "edges" => []
      }
    }

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(payloads_dir, "dummy.txt"), "hello")

    bundle_dir
  end

  def archive_files(bundle_dir) do
    bundle_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      {:ok, contents} = File.read(path)

      %{
        "path" => Path.relative_to(path, bundle_dir),
        "bytes" => byte_size(contents),
        "data" => Base.encode64(contents)
      }
    end)
  end
end
