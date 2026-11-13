defmodule MirrorNeuron.RuntimeReliabilityTest.CleanupTest do
  use MirrorNeuron.RuntimeControlCase, async: false

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Persistence.CancellationStore
  alias MirrorNeuron.Persistence.RedisStore

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

  test "clear discovers a fenced cancellation when its summary is stale" do
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
end
