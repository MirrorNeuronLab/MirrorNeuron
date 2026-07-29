defmodule MirrorNeuron.RuntimeReliabilityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Persistence.{CancellationStore, RedisStore}

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

  test "runtime control and durable delivery timing defaults are conservative" do
    assert Runtime.job_call_timeout_ms() == 15_000
    assert Runtime.cancel_job_call_timeout_ms() == 5_000
    assert Delivery.lease_ms() == 30_000
    assert Delivery.max_attempts() == 10
  end

  test "state-bearing coordinator events are delivered durably before completion" do
    assert Delivery.coordinator_event_requires_ack?("workflow_step_branch")
    assert Delivery.coordinator_event_requires_ack?(:workflow_step_scatter)
    assert Delivery.coordinator_event_requires_ack?("workflow_step_skipped")
    assert Delivery.coordinator_event_requires_ack?("sandbox_job_completed")
  end

  test "runtime control and durable delivery timing honor env overrides" do
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "2500")
    System.put_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS", "1500")
    System.put_env("MN_MESSAGE_ACK_TIMEOUT_MS", "2500")
    System.put_env("MN_MESSAGE_DELIVERY_MAX_ATTEMPTS", "3")

    assert Runtime.job_call_timeout_ms() == 2_500
    assert Runtime.cancel_job_call_timeout_ms() == 1_500
    assert Delivery.lease_ms() == 2_500
    assert Delivery.max_attempts() == 3

    Application.put_env(:mirror_neuron, :job_call_timeout_ms, 4_000)
    Application.put_env(:mirror_neuron, :cancel_job_call_timeout_ms, 2_000)
    Application.put_env(:mirror_neuron, :message_ack_timeout_ms, 4_500)
    Application.put_env(:mirror_neuron, :message_delivery_max_attempts, 7)
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "0")
    System.put_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS", "0")
    System.delete_env("MN_MESSAGE_ACK_TIMEOUT_MS")
    System.delete_env("MN_MESSAGE_DELIVERY_MAX_ATTEMPTS")

    assert Runtime.job_call_timeout_ms() == 4_000
    assert Runtime.cancel_job_call_timeout_ms() == 2_000
    assert Delivery.lease_ms() == 4_500
    assert Delivery.max_attempts() == 7
  end

  test "missing runtime job returns a structured not-running error" do
    job_id = unique_id("missing-job")

    assert {:error, {:job_not_running, ^job_id}} = Runtime.pause_job(job_id)
    assert Runtime.error_message({:job_not_running, job_id}) =~ "not running"
  end

  test "job control call timeout stays local to the caller" do
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "10")
    job_id = unique_id("slow-job")
    pid = start_supervised!({SlowJob, job_id})

    capture_log(fn ->
      assert {:error, {:job_call_timeout, ^job_id, 10}} = Runtime.pause_job(job_id)
    end)

    Process.exit(pid, :kill)
  end

  test "cancellation reconciliation terminates a local runner without calling cancel" do
    job_id = unique_id("local-job-stop")

    assert {:ok, pid} =
             Horde.DynamicSupervisor.start_child(
               MirrorNeuron.Runtime.JobSupervisor,
               {SlowJob, job_id}
             )

    monitor = Process.monitor(pid)
    started_at = System.monotonic_time(:millisecond)

    assert :ok = Runtime.terminate_local_job(job_id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  test "cancel records durable intent before an unreachable owner can time out" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("deferred-cancel-job")
        remote_node = "mirror_neuron@unreachable"

        assert {:ok, _job} = RedisStore.persist_job(job_id, active_job(job_id))

        assert {:ok, _agent} =
                 RedisStore.persist_agent(job_id, "worker", %{
                   "agent_id" => "worker",
                   "assigned_node" => remote_node,
                   "lease_epoch" => 1
                 })

        started_at = System.monotonic_time(:millisecond)
        assert {:ok, "cancellation_pending"} = MirrorNeuron.cancel(job_id)
        cancel_duration = System.monotonic_time(:millisecond) - started_at
        assert cancel_duration < Runtime.cancel_job_call_timeout_ms()

        assert {:ok, job} = RedisStore.fetch_job(job_id)
        assert job["status"] == "cancelling"
        assert is_integer(job["cancellation_fence_epoch"])

        assert {:ok, cancellation} = CancellationStore.fetch(job_id)
        assert cancellation["target_nodes"] == [remote_node]
        assert cancellation["acknowledged_nodes"] == []

        assert {:ok, [%{"job_id" => ^job_id}]} =
                 CancellationStore.list_pending_for_node(remote_node)

        guard_key = "#{System.fetch_env!("MN_REDIS_NAMESPACE")}:job:#{job_id}:guard"

        assert {:ok, encoded_guard} =
                 Redix.command(MirrorNeuron.Redis.Connection, ["GET", guard_key])

        assert {:ok, %{"cancellation_fence_epoch" => fence_epoch}} =
                 Jason.decode(encoded_guard)

        assert fence_epoch >= 1

        stale_write = Map.put(active_job(job_id), "lease_epoch", 1)

        assert {:error, {:cancellation_fenced, 1, _fence_epoch}} =
                 RedisStore.persist_job(job_id, stale_write)

        assert {:error, {:cancellation_fenced, 1, _fence_epoch}} =
                 RedisStore.persist_agent(job_id, "worker", %{
                   "agent_id" => "worker",
                   "assigned_node" => remote_node,
                   "lease_epoch" => 1
                 })

        assert {:error, {:job_cancelling, ^job_id}} = Runtime.resume_job(job_id)

        assert {:ok, :completed, _cancellation} =
                 CancellationStore.acknowledge(job_id, remote_node)

        assert {:ok, %{"status" => "cancelled"}} = RedisStore.fetch_job(job_id)
        assert {:ok, %{"status" => "acknowledged"}} = CancellationStore.fetch(job_id)
        assert {:ok, []} = CancellationStore.list_pending_for_node(remote_node)
      end)
    end
  end

  test "repeated cancellation reuses the durable request" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("idempotent-cancel-job")
        remote_node = "mirror_neuron@unreachable"

        assert {:ok, _job} = RedisStore.persist_job(job_id, active_job(job_id))

        assert {:ok, _agent} =
                 RedisStore.persist_agent(job_id, "worker", %{
                   "agent_id" => "worker",
                   "assigned_node" => remote_node,
                   "lease_epoch" => 1
                 })

        assert {:ok, "cancellation_pending"} = MirrorNeuron.cancel(job_id)
        assert {:ok, first} = CancellationStore.fetch(job_id)
        assert {:ok, "cancellation_pending"} = MirrorNeuron.cancel(job_id)
        assert {:ok, second} = CancellationStore.fetch(job_id)
        assert second["request_id"] == first["request_id"]
      end)
    end
  end

  test "cancellation records assigned, placed, and lease-owner nodes" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("cancellation-targets-job")
        assigned_node = "mirror_neuron@assigned"
        placed_node = "mirror_neuron@placed"
        lease_owner = "mirror_neuron@lease-owner"

        job =
          job_id
          |> active_job()
          |> Map.put("lease_owner", lease_owner)
          |> Map.put("scheduler", %{
            "placements" => [
              %{"agent_id" => "worker", "node" => placed_node},
              %{"agent_id" => "worker", "node" => assigned_node}
            ]
          })

        assert {:ok, _job} = RedisStore.persist_job(job_id, job)

        assert {:ok, _agent} =
                 RedisStore.persist_agent(job_id, "worker", %{
                   "agent_id" => "worker",
                   "assigned_node" => assigned_node,
                   "lease_epoch" => 1
                 })

        assert {:ok, "cancellation_pending"} = MirrorNeuron.cancel(job_id)
        assert {:ok, cancellation} = CancellationStore.fetch(job_id)

        assert cancellation["target_nodes"] == [assigned_node, placed_node, lease_owner]
      end)
    end
  end

  test "durably cancelling jobs can be cleared while remote cleanup remains pending" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("tombstone-clear-job")
        remote_node = "mirror_neuron@offline"

        assert {:ok, _job} = RedisStore.persist_job(job_id, active_job(job_id))

        assert {:ok, _agent} =
                 RedisStore.persist_agent(job_id, "worker", %{
                   "agent_id" => "worker",
                   "assigned_node" => remote_node,
                   "lease_epoch" => 1
                 })

        assert {:ok, _event} =
                 RedisStore.append_event(job_id, %{
                   "type" => "worker_started"
                 })

        delivery_key = redis_key(["job", job_id, "delivery", "worker", "message-1"])
        delivery_index_key = redis_key(["job", job_id, "delivery_keys"])

        assert {:ok, "OK"} =
                 Redix.command(MirrorNeuron.Redis.Connection, ["SET", delivery_key, "queued"])

        assert {:ok, 1} =
                 Redix.command(MirrorNeuron.Redis.Connection, [
                   "SADD",
                   delivery_index_key,
                   delivery_key
                 ])

        assert {:ok, "cancellation_pending"} = MirrorNeuron.cancel(job_id)

        assert {:ok,
                %{
                  "cleanup_deferred" => true,
                  "cleanup_pending_nodes" => [^remote_node]
                }} = Runtime.clear_job_with_result(job_id)

        assert {:error, "job " <> _} = RedisStore.fetch_job(job_id)
        assert {:ok, []} = RedisStore.list_agents(job_id)
        assert {:ok, []} = RedisStore.read_events(job_id)

        assert {:ok, nil} =
                 Redix.command(MirrorNeuron.Redis.Connection, ["GET", delivery_key])

        assert {:ok, cancellation} = CancellationStore.fetch(job_id)
        assert is_binary(cancellation["public_cleared_at"])
        assert cancellation["status"] == "pending"

        guard_key = redis_key("job", job_id, "guard")
        epoch_key = redis_key("lease", "job:#{job_id}", "epoch")

        assert {:ok, encoded_guard} =
                 Redix.command(MirrorNeuron.Redis.Connection, ["GET", guard_key])

        assert is_binary(encoded_guard)

        assert {:error, {:cancellation_fenced, 1, _fence_epoch}} =
                 RedisStore.persist_job(job_id, Map.put(active_job(job_id), "lease_epoch", 1))

        assert :ok =
                 MirrorNeuron.Runtime.EventBus.publish(job_id, %{
                   type: :stale_worker_event
                 })

        assert {:ok, []} = RedisStore.read_events(job_id)

        assert {:ok,
                %{
                  "cleanup_deferred" => true,
                  "cleanup_pending_nodes" => [^remote_node]
                }} = Runtime.clear_job_with_result(job_id)

        assert {:ok, :completed, acknowledged} =
                 CancellationStore.acknowledge(job_id, remote_node)

        assert acknowledged["status"] == "acknowledged"
        assert is_binary(acknowledged["fence_released_at"])
        assert {:ok, nil} = Redix.command(MirrorNeuron.Redis.Connection, ["GET", guard_key])
        assert {:ok, nil} = Redix.command(MirrorNeuron.Redis.Connection, ["GET", epoch_key])
        assert {:ok, []} = CancellationStore.list_pending_for_node(remote_node)
        assert {:error, "job " <> _} = RedisStore.fetch_job(job_id)
      end)
    end
  end

  test "clear operation includes cancellation-pending jobs and reports deferred nodes" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("operation-tombstone-clear-job")
        remote_node = "mirror_neuron@offline-operation"

        assert {:ok, _job} = RedisStore.persist_job(job_id, active_job(job_id))

        assert {:ok, _agent} =
                 RedisStore.persist_agent(job_id, "worker", %{
                   "agent_id" => "worker",
                   "assigned_node" => remote_node,
                   "lease_epoch" => 1
                 })

        assert {:ok, "cancellation_pending"} = MirrorNeuron.cancel(job_id)

        assert {:ok, encoded_summary} =
                 Redix.command(MirrorNeuron.Redis.Connection, [
                   "GET",
                   redis_key(["job", job_id, "summary"])
                 ])

        stale_summary = encoded_summary |> Jason.decode!() |> Map.put("status", "running")

        assert {:ok, "OK"} =
                 Redix.command(MirrorNeuron.Redis.Connection, [
                   "SET",
                   redis_key(["job", job_id, "summary"]),
                   Jason.encode!(stale_summary)
                 ])

        assert {:ok, operation} = MirrorNeuron.start_operation("clear_jobs")

        assert {:ok, completed} =
                 MirrorNeuron.Operations.await(operation["operation_id"], 5_000)

        item = completed["items"][job_id]
        assert item["status"] == "cleared"
        assert item["result"]["cleanup_deferred"] == true
        assert item["result"]["cleanup_pending_nodes"] == [remote_node]
        assert {:error, "job " <> _} = RedisStore.fetch_job(job_id)
      end)
    end
  end

  test "legacy clear discovers a fenced cancellation when its summary is stale" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("legacy-tombstone-clear-job")
        remote_node = "mirror_neuron@offline-legacy"

        assert {:ok, _job} = RedisStore.persist_job(job_id, active_job(job_id))

        assert {:ok, _agent} =
                 RedisStore.persist_agent(job_id, "worker", %{
                   "agent_id" => "worker",
                   "assigned_node" => remote_node,
                   "lease_epoch" => 1
                 })

        assert {:ok, "cancellation_pending"} = MirrorNeuron.cancel(job_id)

        assert {:ok, encoded_summary} =
                 Redix.command(MirrorNeuron.Redis.Connection, [
                   "GET",
                   redis_key(["job", job_id, "summary"])
                 ])

        stale_summary = encoded_summary |> Jason.decode!() |> Map.put("status", "running")

        assert {:ok, "OK"} =
                 Redix.command(MirrorNeuron.Redis.Connection, [
                   "SET",
                   redis_key(["job", job_id, "summary"]),
                   Jason.encode!(stale_summary)
                 ])

        assert {:ok, 1} = MirrorNeuron.Monitor.clear_jobs()
        assert {:error, "job " <> _} = RedisStore.fetch_job(job_id)
        assert {:ok, cancellation} = CancellationStore.fetch(job_id)
        assert is_binary(cancellation["public_cleared_at"])
      end)
    end
  end

  test "running jobs without a cancellation tombstone cannot be cleared" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("unsafe-clear-job")
        assert {:ok, _job} = RedisStore.persist_job(job_id, active_job(job_id))

        assert {:error, :job_is_not_terminal} = Runtime.clear_job_with_result(job_id)
        assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(job_id)
      end)
    end
  end

  test "reconciliation after public clear does not recreate job event keys" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("cleared-reconciliation-job")
        local_node = to_string(Node.self())

        assert {:ok, _job} = RedisStore.persist_job(job_id, active_job(job_id))
        assert {:ok, :created, _cancellation} = CancellationStore.request(job_id, [local_node])
        assert {:ok, _result} = Runtime.clear_job_with_result(job_id)
        assert :ok = MirrorNeuron.Runtime.CancellationReconciler.reconcile_now(job_id)

        assert {:ok, 0} =
                 Redix.command(MirrorNeuron.Redis.Connection, [
                   "EXISTS",
                   redis_key("job", job_id, "events")
                 ])

        assert {:ok, %{"status" => "acknowledged"}} = CancellationStore.fetch(job_id)

        assert {:ok, acknowledged} = CancellationStore.fetch(job_id)
        assert :ok = MirrorNeuron.Runtime.CancellationReconciler.reconcile_now(job_id)
        assert {:ok, repeated} = CancellationStore.fetch(job_id)
        assert repeated["acknowledged_at"] == acknowledged["acknowledged_at"]
        assert repeated["fence_released_at"] == acknowledged["fence_released_at"]

        assert {:ok, 0} =
                 Redix.command(MirrorNeuron.Redis.Connection, [
                   "EXISTS",
                   redis_key("job", job_id, "events")
                 ])
      end)
    end
  end

  test "delivery is durably accepted even while the target agent is unavailable" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("delivery-job")
        agent_id = "missing-agent"
        message_id = unique_id("message")

        message =
          MirrorNeuron.Message.new(job_id, "source", agent_id, "hello", %{},
            message_id: message_id
          )

        assert :ok = Runtime.deliver(job_id, agent_id, message)

        assert {:ok, receipt} =
                 RedisStore.fetch_delivery_receipt(job_id, agent_id, message_id)

        assert receipt["status"] == "queued"
        assert receipt["attempts"] == 0
      end)
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp active_job(job_id) do
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

  defp with_isolated_redis_namespace(fun) do
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

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp redis_key(parts) when is_list(parts) do
    Enum.join([System.fetch_env!("MN_REDIS_NAMESPACE") | parts], ":")
  end

  defp redis_key(part1, part2, part3), do: redis_key([part1, part2, part3])

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
