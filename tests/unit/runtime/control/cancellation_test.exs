defmodule MirrorNeuron.RuntimeReliabilityTest.CancellationTest do
  use MirrorNeuron.RuntimeControlCase, async: false

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Persistence.CancellationStore
  alias MirrorNeuron.Persistence.RedisStore

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

        assert {:error, {:job_cancelling, ^job_id}} = Runtime.pause_job(job_id)
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
end
