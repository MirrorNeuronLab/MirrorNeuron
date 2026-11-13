defmodule MirrorNeuron.Persistence.RedisStore.DeliveryTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Delivery

  test "durable delivery records are idempotent, acknowledged, deleted, and expiring", %{
    namespace: namespace
  } do
    job_id = "delivery-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{"status" => "running", "delivery_version" => 2})

    agent_id = "worker"
    message_id = "message-#{System.unique_integer([:positive])}"
    consumer = Delivery.consumer_id(job_id, agent_id)

    message =
      Message.new(job_id, "source", agent_id, "work", %{"value" => 1}, message_id: message_id)

    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, message)
    assert {:ok, %{status: :duplicate}} = Delivery.enqueue(job_id, agent_id, message)

    conflicting = put_in(message, ["body", "value"], 2)

    assert {:error, {:message_id_conflict, ^message_id, "queued"}} =
             Delivery.enqueue(job_id, agent_id, conflicting)

    assert {:ok, [delivery]} = Delivery.read(job_id, agent_id, consumer)
    assert delivery.message_id == message_id
    assert delivery.attempt == 1
    assert get_in(delivery.message, ["body", "value"]) == 1

    assert :ok = Delivery.ack(job_id, agent_id, consumer, delivery)
    assert {:ok, receipt} = RedisStore.fetch_delivery_receipt(job_id, agent_id, message_id)
    assert receipt["status"] == "acked"
    assert receipt["attempts"] == 1

    stream_key = redis_key(namespace, ["job", job_id, "agent", agent_id, "deliveries"])
    receipt_key = redis_key(namespace, ["job", job_id, "delivery", agent_id, message_id])
    index_key = redis_key(namespace, ["job", job_id, "delivery_keys"])

    assert {:ok, 0} = Redix.command(MirrorNeuron.Redis.Connection, ["XLEN", stream_key])
    assert {:ok, 3} = Redix.command(MirrorNeuron.Redis.Connection, ["SCARD", index_key])
    assert {:ok, ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", receipt_key])
    assert ttl in 1..Delivery.ack_receipt_ttl_seconds()
  end

  test "delivery identity ignores transport timestamps and attempts" do
    job_id = "delivery-transport-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{"status" => "running", "delivery_version" => 2})

    agent_id = "worker"
    message_id = "message-#{System.unique_integer([:positive])}"

    first =
      Message.new(job_id, "source", agent_id, "work", %{"value" => 1},
        message_id: message_id,
        timestamp: "2026-07-16T00:00:00.000Z",
        attempt: 1
      )

    redelivered =
      first
      |> put_in(["envelope", "timestamp"], "2026-07-16T00:01:00.000Z")
      |> put_in(["envelope", "attempt"], 2)

    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, first)
    assert {:ok, %{status: :duplicate}} = Delivery.enqueue(job_id, agent_id, redelivered)

    conflicting = put_in(redelivered, ["body", "value"], 2)

    assert {:error, {:message_id_conflict, ^message_id, "queued"}} =
             Delivery.enqueue(job_id, agent_id, conflicting)

    RedisStore.delete_job(job_id)
  end

  test "attempt epochs reject stale deliveries and cleanup isolates the new attempt" do
    job_id = "delivery-attempt-fence-#{System.unique_integer([:positive])}"
    agent_id = "worker"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "attempt" => 2,
               "lease_epoch" => 2,
               "updated_at" => Runtime.timestamp()
             })

    stale =
      Message.new(job_id, "old-worker", agent_id, "work", %{"value" => "old"},
        message_id: "old-attempt-message",
        headers: %{"mn.attempt_epoch" => 1}
      )

    assert {:error, {:stale_lease_epoch, 1, 2}} = Delivery.enqueue(job_id, agent_id, stale)

    current =
      Message.new(job_id, "new-worker", agent_id, "work", %{"value" => "new"},
        message_id: "new-attempt-message",
        headers: %{"mn.attempt_epoch" => 2}
      )

    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, current)
    assert {:ok, 1} = RedisStore.delivery_pending_count(job_id, agent_id)

    assert :ok = RedisStore.clear_job_attempt_state(job_id)
    assert {:ok, 0} = RedisStore.delivery_pending_count(job_id, agent_id)
    assert {:ok, []} = RedisStore.list_agents(job_id)

    RedisStore.delete_job(job_id)
  end

  test "unacknowledged deliveries are reclaimed after their lease expires" do
    job_id = "delivery-reclaim-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{"status" => "running", "delivery_version" => 2})

    agent_id = "worker"
    message_id = "message-#{System.unique_integer([:positive])}"

    message =
      Message.new(job_id, "source", agent_id, "work", %{"value" => 1}, message_id: message_id)

    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, message)

    assert {:ok, [first_delivery]} =
             RedisStore.read_deliveries(job_id, agent_id, "consumer-one",
               lease_ms: 30_000,
               max_attempts: Delivery.max_attempts(),
               now_ms: System.system_time(:millisecond),
               count: 1,
               stream_ttl_seconds: Delivery.stream_ttl_seconds()
             )

    assert first_delivery.message_id == message_id
    assert first_delivery.attempt == 1
    Process.sleep(5)

    assert {:ok, []} =
             RedisStore.read_deliveries(job_id, agent_id, "consumer-two",
               lease_ms: 1,
               claim_stale: false,
               ensure_group: false,
               max_attempts: Delivery.max_attempts(),
               now_ms: System.system_time(:millisecond),
               count: 1,
               stream_ttl_seconds: Delivery.stream_ttl_seconds()
             )

    assert {:ok, [second_delivery]} =
             RedisStore.read_deliveries(job_id, agent_id, "consumer-two",
               lease_ms: 1,
               max_attempts: Delivery.max_attempts(),
               now_ms: System.system_time(:millisecond),
               count: 1,
               stream_ttl_seconds: Delivery.stream_ttl_seconds()
             )

    assert second_delivery.message_id == message_id
    assert second_delivery.stream_id == first_delivery.stream_id
    assert second_delivery.attempt == 2

    assert :ok = Delivery.ack(job_id, agent_id, "consumer-two", second_delivery)
    assert {:ok, receipt} = RedisStore.fetch_delivery_receipt(job_id, agent_id, message_id)
    assert receipt["status"] == "acked"
    assert receipt["attempts"] == 2
    assert {:ok, 0} = RedisStore.delivery_pending_count(job_id, agent_id)
  end

  test "queued delivery records and indexes always have ttl", %{namespace: namespace} do
    job_id = "delivery-ttl-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{"status" => "running", "delivery_version" => 2})

    agent_id = "worker"
    message_id = "message-#{System.unique_integer([:positive])}"

    message =
      Message.new(job_id, "source", agent_id, "work", %{},
        message_id: message_id,
        ttl_ms: 5_000
      )

    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, message)

    keys = [
      redis_key(namespace, ["job", job_id, "agent", agent_id, "deliveries"]),
      redis_key(namespace, ["job", job_id, "delivery", agent_id, message_id]),
      redis_key(namespace, ["job", job_id, "delivery_count", agent_id]),
      redis_key(namespace, ["job", job_id, "delivery_count"]),
      redis_key(namespace, ["job", job_id, "delivery_keys"])
    ]

    for key <- keys do
      assert {:ok, ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", key])
      assert ttl > 0
    end

    assert :ok = RedisStore.delete_job(job_id)

    for key <- keys do
      assert {:ok, 0} = Redix.command(MirrorNeuron.Redis.Connection, ["EXISTS", key])
    end
  end

  test "delivery backpressure is bounded and capacity returns after ack" do
    old_agent_limit = Application.get_env(:mirror_neuron, :message_max_pending_per_agent)
    old_job_limit = Application.get_env(:mirror_neuron, :message_max_pending_per_job)
    Application.put_env(:mirror_neuron, :message_max_pending_per_agent, 1)
    Application.put_env(:mirror_neuron, :message_max_pending_per_job, 2)

    on_exit(fn ->
      restore_env(:message_max_pending_per_agent, old_agent_limit)
      restore_env(:message_max_pending_per_job, old_job_limit)
    end)

    job_id = "delivery-cap-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{"status" => "running", "delivery_version" => 2})

    agent_id = "worker"
    consumer = Delivery.consumer_id(job_id, agent_id)
    first = Message.new(job_id, "source", agent_id, "work", %{}, message_id: "first")
    second = Message.new(job_id, "source", agent_id, "work", %{}, message_id: "second")

    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, first)
    assert {:ok, %{status: :duplicate}} = Delivery.enqueue(job_id, agent_id, first)

    assert {:error, {:delivery_backpressure, :agent, 1}} =
             Delivery.enqueue(job_id, agent_id, second)

    assert {:ok, [delivery]} = Delivery.read(job_id, agent_id, consumer)
    assert :ok = Delivery.ack(job_id, agent_id, consumer, delivery)
    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, second)
  end

  test "expired deliveries are dead-lettered and removed from the stream" do
    job_id = "delivery-expired-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{"status" => "running", "delivery_version" => 2})

    agent_id = "worker"
    message_id = "expired"
    consumer = Delivery.consumer_id(job_id, agent_id)

    message =
      Message.new(job_id, "source", agent_id, "work", %{},
        message_id: message_id,
        ttl_ms: 1
      )

    assert {:ok, %{status: :queued}} = Delivery.enqueue(job_id, agent_id, message)
    Process.sleep(5)

    assert {:ok, [%{discard_reason: :expired} = delivery]} =
             Delivery.read(job_id, agent_id, consumer)

    assert :ok = Delivery.dead_letter(job_id, agent_id, delivery, :expired)
    assert {:ok, receipt} = RedisStore.fetch_delivery_receipt(job_id, agent_id, message_id)
    assert receipt["status"] == "dead_letter"
    assert {:ok, 0} = RedisStore.delivery_pending_count(job_id, agent_id)
  end

  test "idle delivery polling and admission use the fenced guard for large definitions", %{
    namespace: namespace
  } do
    alias MirrorNeuron.Runtime.DeliveryChannels
    id = "delivery-projection"

    assert {:ok, _} =
             RedisStore.persist_job(id, %{
               "delivery_version" => 2,
               "manifest" => %{
                 "flow" => %{
                   "nodes" => [
                     %{
                       "node_id" => "source",
                       "config" => %{"backpressure" => %{"max_queue_depth" => 7}}
                     }
                   ]
                 }
               },
               "runtime_topology" => %{
                 "nodes" => [%{"node_id" => "replica", "source_node_id" => "source"}]
               }
             })

    assert {:ok, _} = RedisStore.persist_job_projection(id, %{"status" => "running"})

    assert {:ok, encoded} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["job", id, "guard"])
             ])

    guard = Jason.decode!(encoded)
    # Obsolete guards cannot fall back to reading the full Job.
    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", id, "guard"]),
               Jason.encode!(Map.delete(guard, "delivery"))
             ])

    assert {:error, :unsupported_delivery_settings} = DeliveryChannels.version(id)
    assert {:error, :unsupported_delivery_settings} = DeliveryChannels.limit(id, "replica", [])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", id, "guard"]),
               encoded
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["job", id])
             ])

    assert {:ok, 0} = DeliveryChannels.depth(id, "replica")
    assert {:ok, 2} = DeliveryChannels.version(id)
    assert {:ok, 3} = DeliveryChannels.limit(id, "replica", max_queue_depth: 3)
  end
end
