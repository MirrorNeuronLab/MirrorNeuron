defmodule MirrorNeuron.RuntimeControlCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.RuntimeControlCase
    end
  end

  alias MirrorNeuron.Runtime

  @runtime_envs [
    "MN_JOB_CALL_TIMEOUT_MS",
    "MN_CANCEL_JOB_CALL_TIMEOUT_MS",
    "MN_MESSAGE_ACK_TIMEOUT_MS",
    "MN_MESSAGE_DELIVERY_MAX_ATTEMPTS"
  ]
  @runtime_app_keys [
    :job_call_timeout_ms,
    :cancel_job_call_timeout_ms,
    :message_ack_timeout_ms,
    :message_delivery_max_attempts
  ]

  defmodule SlowJob do
    use GenServer

    def child_spec(job_id) do
      %{
        id: {__MODULE__, job_id},
        start: {__MODULE__, :start_link, [job_id]},
        restart: :temporary
      }
    end

    def start_link(job_id), do: GenServer.start_link(__MODULE__, job_id)

    @impl true
    def init(job_id) do
      {:ok, _pid} = Horde.Registry.register(MirrorNeuron.DistributedRegistry, {:job, job_id}, %{})
      {:ok, %{job_id: job_id}}
    end

    @impl true
    def handle_call(:pause, _from, state) do
      Process.sleep(1_000)
      {:reply, {:ok, "paused"}, state}
    end

    @impl true
    def handle_call(:cancel, _from, state) do
      Process.sleep(10_000)
      {:reply, {:ok, "cancelled"}, state}
    end
  end

  defmodule CrashOnceJob do
    def child_spec({id, table, test_pid}) do
      %{
        id: {__MODULE__, id},
        start: {__MODULE__, :start_link, [{id, table, test_pid}]},
        restart: :transient
      }
    end

    def start_link({id, table, test_pid}) do
      Task.start_link(fn ->
        attempt = :ets.update_counter(table, id, {2, 1}, {id, 0})
        send(test_pid, {:crash_once_job_started, id, attempt})

        if attempt == 1 do
          exit(:expected_clean_attempt_restart)
        end
      end)
    end
  end

  setup do
    old_env = Map.new(@runtime_envs, &{&1, System.get_env(&1)})
    old_app = Map.new(@runtime_app_keys, &{&1, Application.get_env(:mirror_neuron, &1)})

    Enum.each(@runtime_envs, &System.delete_env/1)
    Enum.each(@runtime_app_keys, &Application.delete_env(:mirror_neuron, &1))

    on_exit(fn ->
      Enum.each(old_env, fn {key, value} -> restore_system_env(key, value) end)
      Enum.each(old_app, fn {key, value} -> restore_app_env(key, value) end)
    end)

    :ok
  end

  def unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  def active_job(job_id) do
    %{
      "job_id" => job_id,
      "graph_id" => "runtime_reliability_test",
      "job_name" => "runtime_reliability_test",
      "status" => "running",
      "submitted_at" => Runtime.timestamp(),
      "updated_at" => Runtime.timestamp(),
      "root_agent_ids" => ["worker"],
      "placement_policy" => "local",
      "recovery_policy" => "local_restart",
      "manifest_ref" => %{},
      "result" => nil
    }
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

  def with_isolated_redis_namespace(fun) do
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_wait_replicas = Application.get_env(:mirror_neuron, :redis_wait_replicas)
    old_wait_timeout = Application.get_env(:mirror_neuron, :redis_wait_timeout_ms)
    namespace = "mirror_neuron_runtime_reliability_test_#{System.unique_integer([:positive])}"

    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    Application.put_env(:mirror_neuron, :redis_wait_replicas, 0)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 100)

    try do
      fun.()
    after
      cleanup_namespace(namespace)
      restore_app_env(:redis_namespace, old_namespace)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_app_env(:redis_wait_replicas, old_wait_replicas)
      restore_app_env(:redis_wait_timeout_ms, old_wait_timeout)
    end
  end

  def cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  def redis_key(parts) when is_list(parts) do
    Enum.join([System.fetch_env!("MN_REDIS_NAMESPACE") | parts], ":")
  end

  def redis_key(part1, part2, part3), do: redis_key([part1, part2, part3])

  def restore_system_env(key, nil), do: System.delete_env(key)
  def restore_system_env(key, value), do: System.put_env(key, value)
  def restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  def restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
