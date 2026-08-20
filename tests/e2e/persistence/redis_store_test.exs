defmodule MirrorNeuron.Persistence.RedisStoreTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Bundle.{Archive, Fingerprint}
  alias MirrorNeuron.Artifacts.JobStore
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.{DiskCheckpoint, RedisStore}
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.ServiceRegistry

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

  test "append_event trims old events using configured retention" do
    Application.put_env(:mirror_neuron, :event_max_count, 3)
    job_id = "event-retention-#{System.unique_integer([:positive])}"

    for seq <- 1..5 do
      assert {:ok, _event} = RedisStore.append_event(job_id, %{"type" => "test", "seq" => seq})
    end

    assert {:ok, events} = RedisStore.read_events(job_id)
    assert Enum.map(events, & &1["seq"]) == [3, 4, 5]

    RedisStore.delete_job(job_id)
  end

  test "stable job definitions never collide with run records" do
    stable_job_id = "job-stable-#{System.unique_integer([:positive])}"
    run_id = "run-#{System.unique_integer([:positive])}"

    assert {:ok, definition} =
             RedisStore.persist_job_definition(stable_job_id, %{
               "status" => "active",
               "run_ids" => [run_id],
               "data_generation" => 1
             })

    assert definition["job_id"] == stable_job_id

    assert {:ok, _run} =
             RedisStore.persist_job(run_id, %{"job_id" => run_id, "status" => "pending"})

    assert {:ok, fetched_definition} = RedisStore.fetch_job_definition(stable_job_id)
    assert fetched_definition["run_ids"] == [run_id]
    assert {:ok, fetched_run} = RedisStore.fetch_job(run_id)
    assert fetched_run["job_id"] == run_id
    assert {:ok, definitions} = RedisStore.list_job_definitions()
    assert Enum.any?(definitions, &(&1["job_id"] == stable_job_id))

    assert :ok = RedisStore.delete_job_definition(stable_job_id)
    assert {:ok, _run} = RedisStore.fetch_job(run_id)
    assert :ok = RedisStore.delete_job(run_id)
  end

  test "durable delivery records are idempotent, acknowledged, deleted, and expiring", %{
    namespace: namespace
  } do
    job_id = "delivery-#{System.unique_integer([:positive])}"
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

  test "trigger events use the bounded list and retention removes legacy standalone keys", %{
    namespace: namespace
  } do
    suspend_retention()
    event_id = "trigger-event-#{System.unique_integer([:positive])}"
    legacy_id = "legacy-trigger-event-#{System.unique_integer([:positive])}"

    assert {:ok, event} =
             RedisStore.append_trigger_event(event_id, %{
               "event_type" => "test",
               "payload" => %{"value" => 1}
             })

    assert event["event_id"] == event_id
    assert {:ok, [listed]} = RedisStore.list_trigger_events(1)
    assert listed["event_id"] == event_id

    assert {:ok, nil} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["trigger", "event", event_id])
             ])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["trigger", "event", legacy_id]),
               Jason.encode!(event)
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_trigger_event_key_count == 1

    assert {:ok, nil} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["trigger", "event", legacy_id])
             ])
  end

  test "agent observations are compacted before Redis persistence" do
    job_id = "redis-only-agent-snapshot-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "redis-only-agent-snapshot",
               "status" => "pending",
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    snapshot = %{
      "agent_id" => "worker",
      "current_state" => %{"phase" => "starting"},
      "last_heartbeat_at" => MirrorNeuron.Runtime.timestamp()
    }

    assert {:ok, observation} =
             RedisStore.persist_agent(job_id, "worker", snapshot, persist_disk?: false)

    assert observation["agent_id"] == "worker"
    refute Map.has_key?(observation, "current_state")
    assert {:ok, ^observation} = RedisStore.fetch_agent(job_id, "worker")

    RedisStore.delete_job(job_id)
  end

  test "job guards keep lifecycle checks independent of large workflow state", %{
    namespace: namespace
  } do
    job_id = "compact-job-guard-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => 7,
               "updated_at" => "2026-07-19T12:00:00Z",
               "workflow_state" => %{"payload" => String.duplicate("x", 500_000)}
             })

    full_key = redis_key(namespace, ["job", job_id])
    guard_key = redis_key(namespace, ["job", job_id, "guard"])

    assert {:ok, encoded_guard} =
             Redix.command(MirrorNeuron.Redis.Connection, ["GET", guard_key])

    assert {:ok,
            %{
              "job_id" => ^job_id,
              "status" => "running",
              "lease_epoch" => 7,
              "updated_at" => "2026-07-19T12:00:00Z"
            }} = Jason.decode(encoded_guard)

    assert {:ok, full_bytes} = Redix.command(MirrorNeuron.Redis.Connection, ["STRLEN", full_key])
    assert byte_size(encoded_guard) < div(full_bytes, 100)

    RedisStore.delete_job(job_id)
  end

  test "job projections update monitoring without rewriting the durable snapshot", %{
    namespace: namespace
  } do
    job_id = "job-projection-#{System.unique_integer([:positive])}"

    durable = %{
      "job_id" => job_id,
      "status" => "running",
      "lease_epoch" => 3,
      "lease" => %{"owner_id" => "runtime@lab", "epoch" => 3},
      "updated_at" => "2026-07-19T12:00:00Z",
      "scheduler" => %{
        "status" => "scheduled",
        "job_type" => "batch",
        "placement_count" => 2,
        "placements" => [
          %{
            "agent_id" => "first",
            "node" => "runtime@lab",
            "diagnostics" => String.duplicate("x", 50_000)
          },
          %{"agent_id" => "second", "node" => "runtime@lab"}
        ]
      },
      "workflow_state" => %{"durable_marker" => "first"}
    }

    projection =
      durable
      |> Map.put("updated_at", "2026-07-19T12:00:30Z")
      |> Map.put("workflow_state", %{"durable_marker" => "projected-only"})

    assert {:ok, ^durable} = RedisStore.persist_job(job_id, durable)
    assert {:ok, ^projection} = RedisStore.persist_job_projection(job_id, projection)
    assert {:ok, ^durable} = RedisStore.fetch_job(job_id)

    assert {:ok, summaries} = RedisStore.list_job_summaries()

    summary = Enum.find(summaries, &(&1["job_id"] == job_id))
    assert %{"updated_at" => "2026-07-19T12:00:30Z"} = summary
    assert summary["lease_owner"] == "runtime@lab"
    assert summary["scheduler"]["nodes"] == ["runtime@lab"]
    assert summary["scheduler"]["placement_count"] == 2
    refute Map.has_key?(summary["scheduler"], "placements")

    summary_key = redis_key(namespace, ["job", job_id, "summary"])

    assert {:ok, encoded_summary} =
             Redix.command(MirrorNeuron.Redis.Connection, ["GET", summary_key])

    assert byte_size(encoded_summary) < 5_000

    guard_key = redis_key(namespace, ["job", job_id, "guard"])
    assert {:ok, encoded_guard} = Redix.command(MirrorNeuron.Redis.Connection, ["GET", guard_key])
    assert {:ok, %{"updated_at" => "2026-07-19T12:00:30Z"}} = Jason.decode(encoded_guard)

    RedisStore.delete_job(job_id)
  end

  test "active job snapshots persist until the job becomes terminal", %{namespace: namespace} do
    Application.put_env(:mirror_neuron, :agent_snapshot_ttl_seconds, 120)
    job_id = "active-snapshot-retention-#{System.unique_integer([:positive])}"
    agent_id = "worker"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "active_snapshot_retention",
               "status" => "paused",
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, _agent} =
             RedisStore.persist_agent(job_id, agent_id, %{
               "agent_id" => agent_id,
               "last_heartbeat_at" => MirrorNeuron.Runtime.timestamp()
             })

    agent_key = redis_key(namespace, ["job", job_id, "agent", agent_id])
    agents_key = redis_key(namespace, ["job", job_id, "agents"])

    assert {:ok, -1} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agent_key])
    assert {:ok, -1} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agents_key])

    assert {:ok, _job} = RedisStore.persist_terminal_job(job_id, %{"status" => "completed"})

    assert {:ok, agent_ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agent_key])
    assert {:ok, agents_ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", agents_key])
    assert agent_ttl in 1..120
    assert agents_ttl > 0

    RedisStore.delete_job(job_id)
  end

  test "agent observations discard local state and recovery payloads", %{
    namespace: namespace
  } do
    job_id = "compact-agent-summary-#{System.unique_integer([:positive])}"
    agent_id = "worker"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "compact_agent_summary",
               "status" => "running",
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, _agent} =
             RedisStore.persist_agent(job_id, agent_id, %{
               "agent_id" => agent_id,
               "node_id" => agent_id,
               "agent_type" => "executor",
               "assigned_node" => "runtime@lab",
               "processed_messages" => 3,
               "mailbox_depth" => 0,
               "last_heartbeat_at" => MirrorNeuron.Runtime.timestamp(),
               "last_error" => nil,
               "sandbox" => %{"name" => "sandbox-1", "status" => "running"},
               "lease" => %{"lease_id" => "lease-1", "pool" => "default", "slots" => 1},
               "current_state" => %{
                 "runs" => 3,
                 "last_error" => nil,
                 "last_result" => %{
                   "sandbox_name" => "sandbox-1",
                   "lease" => %{"lease_id" => "lease-1", "pool" => "default", "slots" => 1}
                 },
                 "recovery_payload" => String.duplicate("x", 200_000)
               },
               "metadata" => %{
                 "paused" => false,
                 "backpressure" => %{"queue_depth" => 0},
                 "recovery_state" => String.duplicate("y", 200_000)
               }
             })

    assert {:ok, [summary]} = RedisStore.list_agent_summaries(job_id)
    assert summary["agent_id"] == agent_id
    assert summary["sandbox"]["name"] == "sandbox-1"
    assert summary["lease"]["lease_id"] == "lease-1"
    refute Map.has_key?(summary, "current_state")
    refute Map.has_key?(summary["metadata"], "recovery_state")

    assert {:ok, full_observation} = RedisStore.fetch_agent(job_id, agent_id)
    refute Map.has_key?(full_observation, "current_state")
    refute Map.has_key?(full_observation["metadata"], "recovery_state")

    full_key = redis_key(namespace, ["job", job_id, "agent", agent_id])
    summary_key = redis_key(namespace, ["job", job_id, "agent_summary", agent_id])
    assert {:ok, full_bytes} = Redix.command(MirrorNeuron.Redis.Connection, ["STRLEN", full_key])

    assert {:ok, summary_bytes} =
             Redix.command(MirrorNeuron.Redis.Connection, ["STRLEN", summary_key])

    assert full_bytes < 2_000
    assert summary_bytes == full_bytes

    RedisStore.delete_job(job_id)
  end

  test "persists deployments and immutable version records" do
    deployment_id = "dep-test-#{System.unique_integer([:positive])}"
    deployment_key = "agent-api"

    assert {:ok, deployment} =
             RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => deployment_key,
               "status" => "successful",
               "current_version" => "1"
             })

    assert deployment["deployment_id"] == deployment_id
    assert {:ok, fetched} = RedisStore.fetch_deployment(deployment_id)
    assert fetched["deployment_key"] == deployment_key
    assert {:ok, fetched_by_key} = RedisStore.fetch_deployment_by_key(deployment_key)
    assert fetched_by_key["deployment_id"] == deployment_id

    assert {:ok, version} =
             RedisStore.persist_job_version(deployment_key, "1", %{
               "job_id" => "job-1",
               "manifest" => %{"graph_id" => "agent-api"},
               "stable" => true
             })

    assert version["version"] == "1"
    assert {:ok, fetched_version} = RedisStore.fetch_job_version(deployment_key, "1")
    assert fetched_version["job_id"] == "job-1"
    assert {:ok, [listed_version]} = RedisStore.list_job_versions(deployment_key)
    assert listed_version["stable"] == true
  end

  test "deployment key reassignment removes the previous ownership indexes", %{
    namespace: namespace
  } do
    deployment_id = "reindexed-deployment-#{System.unique_integer([:positive])}"
    old_key = "deployment-old"
    new_key = "deployment-new"

    assert {:ok, _deployment} =
             RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => old_key,
               "status" => "running"
             })

    assert {:ok, _deployment} =
             RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => new_key,
               "status" => "successful"
             })

    assert {:error, _reason} = RedisStore.fetch_deployment_by_key(old_key)

    assert {:ok, %{"deployment_id" => ^deployment_id}} =
             RedisStore.fetch_deployment_by_key(new_key)

    assert {:ok, nil} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["deployment", "key", old_key, "current"])
             ])

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployment", "key", old_key, "deployments"]),
               deployment_id
             ])
  end

  test "concurrent deployment updates leave exactly one current owner", %{namespace: namespace} do
    deployment_id = "concurrent-deployment-#{System.unique_integer([:positive])}"
    deployment_keys = ["concurrent-a", "concurrent-b"]

    for _round <- 1..10 do
      results =
        deployment_keys
        |> Task.async_stream(
          fn deployment_key ->
            RedisStore.persist_deployment(deployment_id, %{
              "deployment_key" => deployment_key,
              "status" => "running"
            })
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, {:ok, _deployment}}, &1))
      assert {:ok, winner} = RedisStore.fetch_deployment(deployment_id)

      ownership =
        Enum.map(deployment_keys, fn deployment_key ->
          {:ok, current} =
            Redix.command(MirrorNeuron.Redis.Connection, [
              "GET",
              redis_key(namespace, ["deployment", "key", deployment_key, "current"])
            ])

          {:ok, membership} =
            Redix.command(MirrorNeuron.Redis.Connection, [
              "SISMEMBER",
              redis_key(namespace, ["deployment", "key", deployment_key, "deployments"]),
              deployment_id
            ])

          {deployment_key, current, membership}
        end)

      assert Enum.count(ownership, fn {_key, current, member} ->
               current == deployment_id and member == 1
             end) == 1

      assert {winner["deployment_key"], deployment_id, 1} in ownership
    end
  end

  test "retention compacts missing deployment metadata and preserves corrupt records", %{
    namespace: namespace
  } do
    suspend_retention()
    missing_id = "missing-deployment-#{System.unique_integer([:positive])}"
    corrupt_id = "corrupt-deployment-#{System.unique_integer([:positive])}"
    missing_key = "missing-deployment-key"
    corrupt_key = "corrupt-deployment-key"

    for {deployment_id, deployment_key} <- [
          {missing_id, missing_key},
          {corrupt_id, corrupt_key}
        ] do
      assert {:ok, _deployment} =
               RedisStore.persist_deployment(deployment_id, %{
                 "deployment_key" => deployment_key,
                 "status" => "successful"
               })

      assert {:ok, _version} =
               RedisStore.persist_job_version(deployment_key, "1", %{"job_id" => "job-1"})
    end

    assert {:ok, 2} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["deployment", missing_id]),
               redis_key(namespace, ["deployment", "key", missing_key, "version", "1"])
             ])

    assert {:ok, ["OK", "OK"]} =
             Redix.pipeline(MirrorNeuron.Redis.Connection, [
               [
                 "SET",
                 redis_key(namespace, ["deployment", corrupt_id]),
                 "not-json"
               ],
               [
                 "SET",
                 redis_key(namespace, ["deployment", "key", corrupt_key, "version", "1"]),
                 "not-json"
               ]
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_deployments == [missing_id]
    assert result.stale_deployment_count == 1
    assert result.stale_deployment_version_count == 1

    assert_deployment_membership(namespace, missing_id, missing_key, 0, nil)
    assert_deployment_membership(namespace, corrupt_id, corrupt_key, 1, corrupt_id)

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployment", "key", missing_key, "versions"]),
               "1"
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployment", "key", corrupt_key, "versions"]),
               "1"
             ])
  end

  test "service discovery hides deployment candidates until promoted" do
    assert {:ok, _registered_service} =
             ServiceRegistry.register(%{
               "id" => "svc-candidate",
               "name" => "agent-api",
               "status" => "passing",
               "deployment_key" => "agent-api",
               "deployment_version" => "2",
               "deployment_role" => "canary"
             })

    assert {:ok, []} = ServiceRegistry.resolve("agent-api")
    assert {:ok, [candidate]} = ServiceRegistry.resolve("agent-api", include_candidates: true)
    assert candidate["deployment_role"] == "canary"

    assert {:ok, [_promoted]} = ServiceRegistry.promote_deployment("agent-api", "2")
    assert {:ok, [primary]} = ServiceRegistry.resolve("agent-api")
    assert primary["deployment_role"] == "primary"
  end

  test "read_events can fetch a bounded recent window" do
    job_id = "event-window-#{System.unique_integer([:positive])}"

    for seq <- 1..5 do
      assert {:ok, _event} = RedisStore.append_event(job_id, %{"type" => "test", "seq" => seq})
    end

    assert {:ok, events} = RedisStore.read_events(job_id, -2, -1)
    assert Enum.map(events, & &1["seq"]) == [4, 5]

    RedisStore.delete_job(job_id)
  end

  test "event bus publish persists once and still dispatches to subscribers" do
    job_id = "event-bus-#{System.unique_integer([:positive])}"

    assert {:ok, _} = EventBus.subscribe(job_id)
    assert :ok = EventBus.publish(job_id, %{type: :test_event, payload: %{value: 1}})

    assert_receive {:mirror_neuron_event,
                    %{type: :test_event, payload: %{value: 1}, job_id: ^job_id}},
                   500

    assert {:ok, [%{"type" => "test_event", "payload" => %{"value" => 1}}]} =
             RedisStore.read_events(job_id)

    RedisStore.delete_job(job_id)
  end

  test "event persistence errors stay local and event bus sanitizes runtime diagnostics" do
    bad_job_id = "bad-event-#{System.unique_integer([:positive])}"
    job_id = "safe-event-bus-#{System.unique_integer([:positive])}"
    callback = fn -> :ok end

    assert {:error, _reason} =
             RedisStore.append_event(bad_job_id, %{
               "type" => "bad",
               "callback" => callback
             })

    assert {:ok, _} = EventBus.subscribe(job_id)

    assert :ok =
             EventBus.publish(job_id, %{
               type: :runtime_diagnostic,
               payload: %{
                 callback: callback,
                 owner: self(),
                 tuple: {:runtime, 1},
                 status: :ok
               }
             })

    assert_receive {:mirror_neuron_event,
                    %{
                      type: :runtime_diagnostic,
                      payload: %{callback: received_callback, owner: owner}
                    }},
                   500

    assert is_function(received_callback, 0)
    assert owner == self()

    assert {:ok, [stored]} = RedisStore.read_events(job_id)
    assert stored["type"] == "runtime_diagnostic"
    assert stored["payload"]["callback"] =~ "#Function"
    assert stored["payload"]["owner"] =~ "#PID"
    assert stored["payload"]["tuple"] == "{:runtime, 1}"
    assert stored["payload"]["status"] == "ok"
  end

  test "service registry persists, resolves passing instances, and deregisters by agent" do
    job_id = "service-registry-#{System.unique_integer([:positive])}"

    passing = %{
      "id" => "#{job_id}:worker:ollama",
      "name" => "ollama",
      "job_id" => job_id,
      "agent_id" => "worker",
      "node" => "gpu@lab",
      "address" => "127.0.0.1",
      "port" => 11_434,
      "tags" => ["gpu"],
      "status" => "passing"
    }

    critical =
      passing
      |> Map.put("id", "#{job_id}:other:ollama")
      |> Map.put("agent_id", "other")
      |> Map.put("node", "cpu@lab")
      |> Map.put("status", "critical")

    assert {:ok, _} = ServiceRegistry.register(passing)
    assert {:ok, _} = ServiceRegistry.register(critical)

    assert {:ok, [resolved]} = ServiceRegistry.resolve("ollama", tags: ["gpu"])
    assert resolved["id"] == passing["id"]
    assert resolved["status"] == "passing"

    assert {:ok, all} = ServiceRegistry.list(name: "ollama", passing_only: false)
    assert Enum.count(all, &(&1["job_id"] == job_id)) == 2

    assert ServiceRegistry.requirements_satisfied_on_node?(
             [%{"name" => "ollama", "tags" => ["gpu"]}],
             "gpu@lab"
           )

    refute ServiceRegistry.requirements_satisfied_on_node?(
             [%{"name" => "ollama", "tags" => ["gpu"]}],
             "cpu@lab"
           )

    assert :ok = ServiceRegistry.deregister_agent(job_id, "worker")
    assert {:ok, []} = ServiceRegistry.resolve("ollama", tags: ["gpu"])

    assert :ok = ServiceRegistry.deregister_job(job_id)
  end

  test "re-registering a service replaces its ownership indexes", %{namespace: namespace} do
    instance_id = "reindexed-service-#{System.unique_integer([:positive])}"

    original = %{
      "id" => instance_id,
      "name" => "ollama-old",
      "job_id" => "job-old",
      "agent_id" => "agent-old",
      "node" => "node-old@lab"
    }

    replacement = %{
      "id" => instance_id,
      "name" => "ollama-new",
      "job_id" => "job-new",
      "agent_id" => "agent-new",
      "node" => "node-new@lab"
    }

    assert {:ok, _service} = ServiceRegistry.register(original)
    assert {:ok, _service} = ServiceRegistry.register(replacement)

    for {index, old_value, new_value} <- [
          {"name", "ollama-old", "ollama-new"},
          {"job", "job-old", "job-new"},
          {"agent", "agent-old", "agent-new"},
          {"node", "node-old@lab", "node-new@lab"}
        ] do
      assert {:ok, 0} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SISMEMBER",
                 redis_key(namespace, ["service", index, old_value]),
                 instance_id
               ])

      assert {:ok, 1} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SISMEMBER",
                 redis_key(namespace, ["service", index, new_value]),
                 instance_id
               ])
    end

    assert :ok = ServiceRegistry.deregister_job("job-old")
    assert {:ok, %{"job_id" => "job-new"}} = RedisStore.fetch_service_instance(instance_id)
    assert :ok = ServiceRegistry.deregister_job("job-new")
    assert {:error, _reason} = RedisStore.fetch_service_instance(instance_id)
  end

  test "health updates cannot resurrect a deregistered service" do
    job_id = "deregistered-health-service-#{System.unique_integer([:positive])}"
    instance_id = "#{job_id}:worker:agent-api"

    assert {:ok, registered_service} =
             ServiceRegistry.register(%{
               "id" => instance_id,
               "name" => "agent-api",
               "job_id" => job_id,
               "agent_id" => "worker",
               "node" => to_string(Node.self())
             })

    assert :ok = ServiceRegistry.deregister_job(job_id)

    assert {:error, _reason} =
             RedisStore.update_service_instance_if_exists(
               instance_id,
               Map.put(registered_service, "status", "passing")
             )

    assert {:ok, []} = ServiceRegistry.list(job_id: job_id, passing_only: false)
  end

  test "concurrent service registration cannot leave stale ownership", %{namespace: namespace} do
    instance_id = "concurrent-service-#{System.unique_integer([:positive])}"

    services =
      for suffix <- ["a", "b"] do
        %{
          "id" => instance_id,
          "name" => "ollama-#{suffix}",
          "job_id" => "job-#{suffix}",
          "agent_id" => "agent-#{suffix}",
          "node" => "node-#{suffix}@lab"
        }
      end

    for _round <- 1..10 do
      results =
        services
        |> Task.async_stream(&ServiceRegistry.register/1,
          max_concurrency: 2,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, {:ok, _service}}, &1))
      assert {:ok, winner} = RedisStore.fetch_service_instance(instance_id)

      ownership =
        Enum.map(services, fn service ->
          {:ok, membership} =
            Redix.command(MirrorNeuron.Redis.Connection, [
              "SISMEMBER",
              redis_key(namespace, ["service", "job", service["job_id"]]),
              instance_id
            ])

          {service["job_id"], membership}
        end)

      assert Enum.sum(Enum.map(ownership, &elem(&1, 1))) == 1
      assert {winner["job_id"], 1} in ownership
    end

    assert :ok = ServiceRegistry.deregister_service(instance_id)
  end

  test "owner cleanup reclaims corrupt service records and every index", %{namespace: namespace} do
    job_id = "corrupt-service-job-#{System.unique_integer([:positive])}"
    instance_id = "#{job_id}:worker:ollama"

    service = %{
      "id" => instance_id,
      "name" => "ollama",
      "job_id" => job_id,
      "agent_id" => "worker",
      "node" => "gpu@lab"
    }

    assert {:ok, _service} = ServiceRegistry.register(service)

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["service", "instance", instance_id]),
               "not-json"
             ])

    assert :ok = ServiceRegistry.deregister_job(job_id)
    assert_service_instance_reclaimed(namespace, instance_id, service)
  end

  test "retention compacts indexes for missing service records", %{namespace: namespace} do
    job_id = "missing-service-job-#{System.unique_integer([:positive])}"
    instance_id = "#{job_id}:worker:ollama"

    service = %{
      "id" => instance_id,
      "name" => "ollama",
      "job_id" => job_id,
      "agent_id" => "worker",
      "node" => "gpu@lab"
    }

    assert {:ok, _service} = ServiceRegistry.register(service)

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["service", "instance", instance_id])
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_service_instances == [instance_id]
    assert result.stale_service_instance_count == 1
    assert_service_instance_reclaimed(namespace, instance_id, service)
  end

  test "retention sweep deletes expired terminal jobs and stale job ids" do
    job_id = "terminal-retention-#{System.unique_integer([:positive])}"
    old_job_root = System.get_env("MN_JOB_ARTIFACT_ROOT")

    job_root =
      Path.join(System.tmp_dir!(), "mn_job_artifacts_#{System.unique_integer([:positive])}")

    System.put_env("MN_JOB_ARTIFACT_ROOT", job_root)

    on_exit(fn ->
      restore_system_env("MN_JOB_ARTIFACT_ROOT", old_job_root)
      File.rm_rf(job_root)
    end)

    assert {:ok, job_path} = JobStore.ensure_job_dir(job_id)
    File.write!(Path.join(job_path, "artifact.txt"), "done")

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(job_id, %{"status" => "completed"}, %{
               "graph_id" => "retention_test",
               "job_name" => "retention_test"
             })

    assert {:ok, _job} = RedisStore.fetch_job(job_id)

    assert {:ok, result} = RedisStore.sweep_retention(terminal_job_ttl_seconds: 0)
    assert result.deleted_jobs == [job_id]
    assert result.deleted_count == 1
    assert {:error, _reason} = RedisStore.fetch_job(job_id)
    refute File.exists?(job_path)
  end

  test "retention preserves terminal state when resource cleanup fails" do
    job_id = "deferred-terminal-retention-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(job_id, %{"status" => "completed"}, %{
               "graph_id" => "deferred_retention",
               "job_name" => "deferred retention"
             })

    assert {:ok, result} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: fn ^job_id -> {:error, :resource_busy} end
             )

    refute job_id in result.deleted_jobs
    assert {:ok, %{"status" => "completed"}} = RedisStore.fetch_job(job_id)

    RedisStore.delete_job(job_id)
  end

  test "retention does not clean jobs whose persisted state is unreadable", %{
    namespace: namespace
  } do
    job_id = "unreadable-retention-job-#{System.unique_integer([:positive])}"
    parent = self()

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id]),
               "not-json"
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               job_id
             ])

    assert {:ok, result} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: fn cleanup_job_id, _job ->
                 send(parent, {:cleanup_called, cleanup_job_id})
                 :ok
               end
             )

    refute_receive {:cleanup_called, ^job_id}
    refute job_id in result.stale_job_ids

    assert {:ok, "not-json"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["job", job_id])
             ])
  end

  test "job deletion retains the record when shared storage cannot be removed safely" do
    job_id = "failed-resource-cleanup-#{System.unique_integer([:positive])}"
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    old_artifact_root = System.get_env("MN_JOB_ARTIFACT_ROOT")

    test_root =
      Path.join(System.tmp_dir!(), "mn_failed_cleanup_#{System.unique_integer([:positive])}")

    shared_root = Path.join(test_root, "shared")
    artifact_root = Path.join(test_root, "artifacts")
    outside_submission = Path.join(test_root, "outside-submission")

    File.mkdir_p!(shared_root)
    File.mkdir_p!(outside_submission)
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)
    System.put_env("MN_JOB_ARTIFACT_ROOT", artifact_root)

    on_exit(fn ->
      case RedisStore.fetch_job(job_id) do
        {:ok, job} ->
          _ = RedisStore.persist_job(job_id, Map.put(job, "manifest", %{}))
          _ = RedisStore.delete_job(job_id)

        _other ->
          :ok
      end

      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
      restore_system_env("MN_JOB_ARTIFACT_ROOT", old_artifact_root)
      File.rm_rf(test_root)
    end)

    assert {:ok, artifact_path} = JobStore.ensure_job_dir(job_id)
    File.write!(Path.join(artifact_path, "result.txt"), "remove with terminal job record")

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(job_id, %{
               "status" => "completed",
               "manifest" => %{
                 "metadata" => %{
                   "mn_storage" => %{"submission_path" => outside_submission}
                 }
               }
             })

    assert {:error, "mn_storage.submission_path is outside shared storage root"} =
             RedisStore.delete_job(job_id)

    assert {:ok, _job} = RedisStore.fetch_job(job_id)
    assert File.exists?(artifact_path)
    assert File.dir?(outside_submission)
  end

  test "stable job deletion removes every terminal run and its runtime resources" do
    suffix = System.unique_integer([:positive])
    stable_job_id = "stable-delete-#{suffix}"
    run_ids = ["stable-delete-run-a-#{suffix}", "stable-delete-run-b-#{suffix}"]
    old_job_data_root = System.get_env("MN_JOB_DATA_ROOT")
    old_checkpoint_root = System.get_env("MN_CHECKPOINT_ROOT")
    old_artifact_root = System.get_env("MN_JOB_ARTIFACT_ROOT")
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    root = Path.join(System.tmp_dir!(), "mn_stable_delete_#{suffix}")
    shared_root = Path.join(root, "shared")
    definition_submission = Path.join([shared_root, "submissions", stable_job_id])

    System.put_env("MN_JOB_DATA_ROOT", Path.join(root, "job-data"))
    System.put_env("MN_CHECKPOINT_ROOT", Path.join(root, "checkpoints"))
    System.put_env("MN_JOB_ARTIFACT_ROOT", Path.join(root, "artifacts"))
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)
    File.mkdir_p!(definition_submission)

    on_exit(fn ->
      Enum.each(run_ids, &RedisStore.delete_job/1)
      RedisStore.delete_job_definition(stable_job_id)
      restore_system_env("MN_JOB_DATA_ROOT", old_job_data_root)
      restore_system_env("MN_CHECKPOINT_ROOT", old_checkpoint_root)
      restore_system_env("MN_JOB_ARTIFACT_ROOT", old_artifact_root)
      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
      File.rm_rf(root)
    end)

    retired_resources = %{
      "mn_storage" => %{
        "submission_id" => "#{stable_job_id}-definition",
        "submission_path" => definition_submission
      },
      "mn_docker_workers" => %{"submission_id" => "#{stable_job_id}-definition"}
    }

    assert {:ok, _path} = MirrorNeuron.JobData.initialize(stable_job_id)

    assert {:ok, _definition} =
             RedisStore.persist_job_definition(stable_job_id, %{
               "job_id" => stable_job_id,
               "status" => "active",
               "run_ids" => run_ids,
               "manifest" => %{"metadata" => retired_resources}
             })

    for run_id <- run_ids do
      assert {:ok, _job} =
               RedisStore.persist_terminal_job(run_id, %{
                 "job_id" => run_id,
                 "stable_job_id" => stable_job_id,
                 "status" => "completed",
                 "manifest" => %{}
               })

      assert :ok = DiskCheckpoint.persist_job(run_id, %{"job_id" => run_id})
      assert {:ok, artifact_path} = JobStore.ensure_job_dir(run_id)
      File.write!(Path.join(artifact_path, "result.txt"), "terminal output")

      assert {:ok, _service} =
               ServiceRegistry.register(%{
                 "id" => "service-#{run_id}",
                 "name" => "terminal-service",
                 "job_id" => run_id
               })
    end

    assert {:ok, %{"metadata" => ^retired_resources}} =
             StableJob.delete(stable_job_id, confirmed: true)

    assert {:error, _reason} = RedisStore.fetch_job_definition(stable_job_id)
    refute File.exists?(Path.join(MirrorNeuron.JobData.root(), stable_job_id))
    refute File.exists?(definition_submission)

    for run_id <- run_ids do
      assert {:error, _reason} = RedisStore.fetch_job(run_id)
      assert {:error, :enoent} = DiskCheckpoint.load_job(run_id)
      assert {:ok, artifact_path} = JobStore.job_path(run_id)
      refute File.exists?(artifact_path)
      assert {:ok, []} = ServiceRegistry.list(job_id: run_id)
    end
  end

  test "retention retries sandbox cleanup on disconnected persisted placement nodes" do
    job_id = "disconnected-sandbox-retention-#{System.unique_integer([:positive])}"
    remote_node = :"cleanup-worker@lab"
    old_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)

    assert {:ok, job} =
             RedisStore.persist_terminal_job(job_id, %{
               "status" => "completed",
               "scheduler" => %{
                 "placements" => [%{"agent_id" => "worker", "node" => to_string(remote_node)}]
               }
             })

    CleanupNodeAdapterStub.reset(self())
    Application.put_env(:mirror_neuron, :cluster_node_adapter, CleanupNodeAdapterStub)

    on_exit(fn ->
      restore_env(:cluster_node_adapter, old_adapter)
      RedisStore.delete_job(job_id)
    end)

    assert {:error, failures} = Runtime.cleanup_job_sandboxes(job_id, job)

    assert Enum.map(failures, & &1.node) == [
             to_string(remote_node),
             to_string(remote_node),
             to_string(remote_node)
           ]

    assert_receive {:cleanup_rpc, ^remote_node, MirrorNeuron.Runner.HostLocal, :terminate_job,
                    [^job_id], 15_000}

    assert_receive {:cleanup_rpc, ^remote_node, MirrorNeuron.Sandbox.OpenShellJobSandbox,
                    :cleanup_job_local, [^job_id], 15_000}

    assert_receive {:cleanup_rpc, ^remote_node, MirrorNeuron.Sandbox.DockerJobSandbox,
                    :cleanup_job_local, [^job_id], 15_000}

    assert {:ok, deferred} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: &Runtime.cleanup_job_sandboxes/2
             )

    refute job_id in deferred.deleted_jobs
    assert {:ok, %{"status" => "completed"}} = RedisStore.fetch_job(job_id)

    CleanupNodeAdapterStub.put_remote_result(:ok)

    assert {:ok, reclaimed} =
             RedisStore.sweep_retention(
               terminal_job_ttl_seconds: 0,
               cleanup_job: &Runtime.cleanup_job_sandboxes/2
             )

    assert job_id in reclaimed.deleted_jobs
    assert {:error, _reason} = RedisStore.fetch_job(job_id)
  end

  test "register_blob_ref persists shared filesystem locations without urls" do
    sha256 = String.duplicate("d", 64)
    path = Path.join(binary_part(sha256, 0, 2), sha256)

    ref = %{
      "type" => "blob_ref",
      "sha256" => sha256,
      "locations" => [
        %{
          "node" => "node-a@lab",
          "storage" => "shared_fs",
          "root" => "blob_store",
          "path" => path,
          "status" => "available"
        }
      ]
    }

    assert {:ok, blob} = RedisStore.register_blob_ref(ref)
    assert [%{"storage" => "shared_fs", "path" => ^path} = location] = blob["locations"]
    refute Map.has_key?(location, "url")

    assert {:ok, fetched} = RedisStore.fetch_blob_ref(sha256)
    assert [%{"storage" => "shared_fs", "path" => ^path}] = fetched["locations"]
  end

  test "blob listing and retention compact expired metadata indexes", %{namespace: namespace} do
    active_sha = String.duplicate("a", 64)
    listed_stale_sha = String.duplicate("b", 64)
    swept_stale_sha = String.duplicate("c", 64)

    assert {:ok, _blob} =
             RedisStore.register_blob_ref(%{
               "sha256" => active_sha,
               "locations" => [%{"storage" => "shared_fs", "path" => "aa/#{active_sha}"}]
             })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["blobs"]),
               listed_stale_sha
             ])

    assert {:ok, [%{"sha256" => ^active_sha}]} = RedisStore.list_blob_refs()

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["blobs"]),
               listed_stale_sha
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["blobs"]),
               swept_stale_sha
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_blob_refs == [swept_stale_sha]
    assert result.stale_blob_ref_count == 1

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["blobs"]),
               swept_stale_sha
             ])
  end

  test "retention rebuilds blob metadata still referenced by a persisted job", %{
    namespace: namespace
  } do
    job_id = "blob-retention-job-#{System.unique_integer([:positive])}"
    sha256 = String.duplicate("d", 64)

    ref = %{
      "type" => "blob_ref",
      "sha256" => sha256,
      "payload_path" => "inputs/document.txt",
      "locations" => [%{"storage" => "shared_fs", "path" => "dd/#{sha256}"}]
    }

    assert {:ok, _blob} = RedisStore.register_blob_ref(ref)

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "recovery_status" => "paused_for_review",
               "recovery_requires_review" => true,
               "manifest" => %{"metadata" => %{"blob_refs" => [ref]}},
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["blob", sha256])
             ])

    assert {:error, _reason} = RedisStore.fetch_blob_ref(sha256)
    assert {:ok, _result} = RedisStore.sweep_retention()
    assert {:ok, %{"sha256" => ^sha256}} = RedisStore.fetch_blob_ref(sha256)

    RedisStore.delete_job(job_id)
  end

  test "durable records discover and refresh every referenced bundle archive", %{
    namespace: namespace
  } do
    Application.put_env(:mirror_neuron, :bundle_archive_ttl_seconds, 120)

    job_id = "bundle-ref-job-#{System.unique_integer([:positive])}"
    schedule_id = "bundle-ref-schedule-#{System.unique_integer([:positive])}"
    deployment_key = "bundle-ref-deployment-#{System.unique_integer([:positive])}"
    job_fingerprint = String.duplicate("a", 64)
    schedule_fingerprint = String.duplicate("b", 64)
    version_fingerprint = String.duplicate("c", 64)
    fingerprints = [job_fingerprint, schedule_fingerprint, version_fingerprint]

    on_exit(fn ->
      RedisStore.delete_job(job_id)
      RedisStore.delete_schedule(schedule_id)
    end)

    for fingerprint <- fingerprints do
      assert {:ok, _archive} =
               RedisStore.persist_bundle_archive(fingerprint, %{
                 "graph_id" => "bundle-reference-test",
                 "files" => []
               })
    end

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "manifest_ref" => %{"bundle_fingerprint" => job_fingerprint},
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, _schedule} =
             RedisStore.persist_schedule(schedule_id, %{
               "kind" => "event",
               "status" => "active",
               "enabled" => true,
               "bundle_ref" => %{"bundle_fingerprint" => schedule_fingerprint}
             })

    assert {:ok, _version} =
             RedisStore.persist_job_version(deployment_key, "1", %{
               "manifest_ref" => %{"bundle_fingerprint" => version_fingerprint}
             })

    assert {:ok, ^fingerprints} = RedisStore.referenced_bundle_fingerprints()

    for fingerprint <- fingerprints do
      archive_key = redis_key(namespace, ["bundle", fingerprint])
      assert {:ok, 1} = Redix.command(MirrorNeuron.Redis.Connection, ["EXPIRE", archive_key, "1"])
      assert :ok = RedisStore.refresh_bundle_archive(fingerprint)
      assert {:ok, ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", archive_key])
      assert ttl == -1
    end

    assert :ok = RedisStore.delete_job(job_id)
    assert :ok = RedisStore.delete_schedule(schedule_id)

    assert {:ok, 2} =
             RedisStore.expire_unreferenced_bundle_archives([version_fingerprint])

    for fingerprint <- [job_fingerprint, schedule_fingerprint] do
      assert {:ok, ttl} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "TTL",
                 redis_key(namespace, ["bundle", fingerprint])
               ])

      assert ttl in 100..120
    end

    assert {:ok, -1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "TTL",
               redis_key(namespace, ["bundle", version_fingerprint])
             ])
  end

  test "recovery evals can be listed by active status" do
    pending_id = "pending-eval-#{System.unique_integer([:positive])}"
    complete_id = "complete-eval-#{System.unique_integer([:positive])}"

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(pending_id, %{
               "status" => "pending",
               "created_at" => "2026-01-01T00:00:00Z"
             })

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(complete_id, %{
               "status" => "complete",
               "created_at" => "2026-01-02T00:00:00Z"
             })

    assert {:ok, pending_evals} = RedisStore.list_recovery_evals(["pending", "blocked"])
    assert Enum.map(pending_evals, & &1["eval_id"]) == [pending_id]

    assert {:ok, complete_evals} = RedisStore.list_recovery_evals(["complete"])
    assert Enum.map(complete_evals, & &1["eval_id"]) == [complete_id]

    assert {:ok, _eval} =
             RedisStore.update_recovery_eval(pending_id, %{
               "status" => "complete",
               "completed_at" => "2026-01-03T00:00:00Z"
             })

    assert {:ok, []} = RedisStore.list_recovery_evals(["pending", "blocked"])
    assert {:ok, complete_evals} = RedisStore.list_recovery_evals(["complete"])
    assert Enum.map(complete_evals, & &1["eval_id"]) == [pending_id, complete_id]
  end

  test "repair_recovery_indexes rebuilds recovery eval status indexes", %{namespace: namespace} do
    eval_id = "legacy-eval-#{System.unique_integer([:positive])}"

    eval = %{
      "eval_id" => eval_id,
      "status" => "blocked",
      "created_at" => "2026-01-01T00:00:00Z"
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["recovery", "eval", eval_id]),
               Jason.encode!(eval)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals"]),
               eval_id
             ])

    assert {:ok, []} = RedisStore.list_recovery_evals(["blocked"])

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.repaired_recovery_evals == 1

    assert {:ok, [repaired]} = RedisStore.list_recovery_evals(["blocked"])
    assert repaired["eval_id"] == eval_id
  end

  test "legacy recovery evals with embedded jobs can still be fetched", %{namespace: namespace} do
    eval_id = "legacy-job-eval-#{System.unique_integer([:positive])}"

    legacy_eval = %{
      "eval_id" => eval_id,
      "job_id" => "legacy-job",
      "status" => "complete",
      "job" => %{"job_id" => "legacy-job", "manifest" => %{"graph_id" => "legacy"}}
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["recovery", "eval", eval_id]),
               Jason.encode!(legacy_eval)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals"]),
               eval_id
             ])

    assert {:ok, fetched} = RedisStore.fetch_recovery_eval(eval_id)
    assert fetched["job"]["manifest"]["graph_id"] == "legacy"
  end

  test "terminal recovery evals receive ttl and active evals persist", %{namespace: namespace} do
    System.put_env("MN_RECOVERY_EVAL_TTL_SECONDS", "120")
    complete_id = "ttl-complete-eval-#{System.unique_integer([:positive])}"
    pending_id = "ttl-pending-eval-#{System.unique_integer([:positive])}"

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(complete_id, %{
               "job_id" => "job-a",
               "status" => "complete"
             })

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(pending_id, %{
               "job_id" => "job-a",
               "status" => "pending"
             })

    assert {:ok, complete_ttl} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "TTL",
               redis_key(namespace, ["recovery", "eval", complete_id])
             ])

    assert complete_ttl > 0
    assert complete_ttl <= 120

    assert {:ok, -1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "TTL",
               redis_key(namespace, ["recovery", "eval", pending_id])
             ])
  end

  test "retention sweep does not renew terminal recovery eval ttl", %{namespace: namespace} do
    System.put_env("MN_RECOVERY_EVAL_TTL_SECONDS", "120")
    eval_id = "ttl-not-renewed-eval-#{System.unique_integer([:positive])}"
    eval_key = redis_key(namespace, ["recovery", "eval", eval_id])

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(eval_id, %{
               "job_id" => "job-a",
               "status" => "complete"
             })

    assert {:ok, 1} = Redix.command(MirrorNeuron.Redis.Connection, ["EXPIRE", eval_key, "30"])
    assert {:ok, _result} = RedisStore.sweep_retention()
    assert {:ok, ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", eval_key])
    assert ttl in 1..30
  end

  test "retention sweep removes expired recovery evals and stale index ids",
       %{namespace: namespace} do
    old_eval_id = "expired-eval-#{System.unique_integer([:positive])}"
    stale_eval_id = "stale-eval-#{System.unique_integer([:positive])}"
    status_only_eval_id = "status-only-eval-#{System.unique_integer([:positive])}"

    assert {:ok, _eval} =
             RedisStore.persist_recovery_eval(old_eval_id, %{
               "job_id" => "job-a",
               "status" => "complete",
               "updated_at" => "2026-01-01T00:00:00Z"
             })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals"]),
               stale_eval_id
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals", "status", "complete"]),
               stale_eval_id
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["recovery", "evals", "status", "failed"]),
               status_only_eval_id
             ])

    System.put_env("MN_RECOVERY_EVAL_TTL_SECONDS", "0")

    assert {:ok, result} = RedisStore.sweep_retention()
    assert old_eval_id in result.deleted_recovery_evals
    assert stale_eval_id in result.stale_recovery_evals
    assert status_only_eval_id in result.stale_recovery_evals
    assert {:error, _reason} = RedisStore.fetch_recovery_eval(old_eval_id)

    for {status, eval_id} <- [
          {"complete", old_eval_id},
          {"complete", stale_eval_id},
          {"failed", status_only_eval_id}
        ] do
      assert {:ok, 0} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SISMEMBER",
                 redis_key(namespace, ["recovery", "evals", "status", status]),
                 eval_id
               ])
    end
  end

  test "retention preserves unreadable recovery evals for explicit repair", %{
    namespace: namespace
  } do
    eval_id = "unreadable-eval-#{System.unique_integer([:positive])}"
    recovery = Process.whereis(MirrorNeuron.Runtime.LocalRecovery)

    if recovery, do: :sys.suspend(recovery)

    on_exit(fn ->
      if recovery && Process.alive?(recovery), do: :sys.resume(recovery)
    end)

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["recovery", "eval", eval_id]),
               "not-json"
             ])

    for key_parts <- [
          ["recovery", "evals"],
          ["recovery", "evals", "status", "complete"]
        ] do
      assert {:ok, 1} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SADD",
                 redis_key(namespace, key_parts),
                 eval_id
               ])
    end

    assert {:ok, result} = RedisStore.sweep_retention()
    refute eval_id in result.stale_recovery_evals
    refute eval_id in result.deleted_recovery_evals

    assert {:ok, "not-json"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["recovery", "eval", eval_id])
             ])
  end

  test "repair_recovery_indexes makes job control records discoverable and removes stale jobs",
       %{namespace: namespace} do
    job_id = "repair-job-#{System.unique_integer([:positive])}"
    stale_job_id = "stale-job-#{System.unique_integer([:positive])}"

    job = %{
      "job_id" => job_id,
      "status" => "running",
      "graph_id" => "repair_index_test",
      "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id]),
               Jason.encode!(job)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               stale_job_id
             ])

    assert {:ok, jobs_before} = RedisStore.list_jobs()
    refute Enum.any?(jobs_before, &(&1["job_id"] == job_id))

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.repaired_jobs == 1
    assert result.repaired_agents == 0
    assert result.removed_stale_jobs == 1
    assert result.removed_stale_agents == 0

    assert {:ok, jobs_after} = RedisStore.list_jobs()
    assert Enum.any?(jobs_after, &(&1["job_id"] == job_id))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["jobs"]),
               stale_job_id
             ])

    RedisStore.delete_job(job_id)
  end

  test "repair_recovery_indexes removes corrupt indexed job control records", %{
    namespace: namespace
  } do
    corrupt_job_id = "corrupt-job-#{System.unique_integer([:positive])}"
    job_id = "valid-job-#{System.unique_integer([:positive])}"

    job = %{
      "job_id" => job_id,
      "status" => "running",
      "graph_id" => "corrupt_index_repair_test",
      "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", corrupt_job_id]),
               "{not-json"
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               corrupt_job_id
             ])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["job", job_id]),
               Jason.encode!(job)
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["jobs"]),
               job_id
             ])

    assert {:ok, result} = RedisStore.repair_recovery_indexes()
    assert result.removed_stale_jobs == 1
    assert result.removed_stale_agents == 0

    assert {:ok, jobs} = RedisStore.list_jobs()
    refute Enum.any?(jobs, &(&1["job_id"] == corrupt_job_id))
    assert Enum.any?(jobs, &(&1["job_id"] == job_id))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["jobs"]),
               corrupt_job_id
             ])
  end

  test "list_job_summaries returns compact records and backfills legacy jobs", %{
    namespace: namespace
  } do
    job_id = "summary-job-#{System.unique_integer([:positive])}"
    large_payload = String.duplicate("x", 64_000)

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "summary_demo",
               "status" => "running",
               "submitted_at" => "2026-03-28T00:00:00Z",
               "updated_at" => "2026-03-28T00:00:10Z",
               "manifest" => %{"payload" => large_payload},
               "workflow" => %{"payload" => large_payload}
             })

    assert {:ok, [summary]} = RedisStore.list_job_summaries()
    assert summary["job_id"] == job_id
    assert summary["graph_id"] == "summary_demo"
    refute Map.has_key?(summary, "manifest")
    refute Map.has_key?(summary, "workflow")

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["job", job_id, "summary"])
             ])

    assert {:ok, [backfilled]} = RedisStore.list_job_summaries()
    assert backfilled["job_id"] == job_id

    assert {:ok, encoded_summary} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["job", job_id, "summary"])
             ])

    assert is_binary(encoded_summary)
    assert byte_size(encoded_summary) < 2_000

    RedisStore.delete_job(job_id)
  end

  test "list_job_summaries flags recoverable runner interruptions" do
    job_id = "summary-failed-runner-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "summary_failed_runner",
               "status" => "failed",
               "submitted_at" => "2026-03-28T00:00:00Z",
               "updated_at" => "2026-03-28T00:00:10Z",
               "result" => %{
                 "agent_id" => "job_runner",
                 "error" => "job coordinator exited before terminal state",
                 "reason" => ":normal"
               }
             })

    assert {:ok, [summary]} = RedisStore.list_job_summaries()
    assert summary["job_id"] == job_id
    assert summary["status"] == "failed"
    assert summary["recovery_hint"] == "runner_interruption"

    assert summary["failure"] == %{
             "agent_id" => "job_runner",
             "message" => "job coordinator exited before terminal state"
           }

    refute Map.has_key?(summary, "result")

    RedisStore.delete_job(job_id)
  end

  test "failed job summaries retain bounded structured diagnostics" do
    job_id = "summary-failed-bootstrap-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "summary_failed_bootstrap",
               "status" => "failed",
               "result" => %{
                 "error" => %{
                   "category" => "timeout",
                   "component" => "job_coordinator",
                   "message" => "failed to start agent audit__end: :timeout",
                   "agent_id" => "audit__end",
                   "node" => "mirror_neuron@10.0.4.27",
                   "retryable" => true,
                   "details" => String.duplicate("not-in-summary", 10_000)
                 }
               }
             })

    assert {:ok, [summary]} = RedisStore.list_job_summaries()

    assert summary["failure"] == %{
             "agent_id" => "audit__end",
             "category" => "timeout",
             "component" => "job_coordinator",
             "message" => "failed to start agent audit__end: :timeout",
             "node" => "mirror_neuron@10.0.4.27",
             "retryable" => true
           }

    refute Map.has_key?(summary["failure"], "details")
    RedisStore.delete_job(job_id)
  end

  test "fenced leases reject stale job and agent writes" do
    job_id = "fenced-job-#{System.unique_integer([:positive])}"
    lease_name = "job:#{job_id}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "node-a", 5_000)
    assert lease["epoch"] >= 1

    assert {:error, {:locked, locked}} =
             RedisStore.acquire_fenced_lease(lease_name, "node-b", 5_000)

    assert locked["owner_id"] == "node-a"
    assert locked["epoch"] == lease["epoch"]

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => lease["epoch"]
             })

    assert {:error, {:stale_lease_epoch, stale_epoch, existing_epoch}} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => lease["epoch"] - 1
             })

    assert stale_epoch == lease["epoch"] - 1
    assert existing_epoch == lease["epoch"]

    assert {:error, {:stale_lease_epoch, stale_agent_epoch, existing_agent_epoch}} =
             RedisStore.persist_agent(job_id, "agent-a", %{
               "agent_id" => "agent-a",
               "status" => "running",
               "metadata" => %{"lease_epoch" => lease["epoch"] - 1}
             })

    assert stale_agent_epoch == lease["epoch"] - 1
    assert existing_agent_epoch == lease["epoch"]

    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-a", lease["epoch"])
    assert {:ok, next_lease} = RedisStore.acquire_fenced_lease(lease_name, "node-b", 5_000)
    assert next_lease["epoch"] > lease["epoch"]
    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-b", next_lease["epoch"])
  end

  test "fenced lease renewal and release enforce ownership" do
    lease_name = "lease-test-#{System.unique_integer([:positive])}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "node-a", 1_000)
    assert :ok = RedisStore.renew_fenced_lease(lease_name, "node-a", lease["epoch"], 1_000)

    assert {:error, :not_owner} =
             RedisStore.renew_fenced_lease(lease_name, "node-b", lease["epoch"], 1_000)

    assert {:error, :not_owner} =
             RedisStore.release_fenced_lease(lease_name, "node-b", lease["epoch"])

    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-a", lease["epoch"])
  end

  test "fenced schedule writes reject an expired state owner and deletion reclaims leases", %{
    namespace: namespace
  } do
    schedule_id = "fenced-schedule-#{System.unique_integer([:positive])}"
    lease_name = "schedule:#{schedule_id}:state"
    dispatch_lease_name = "schedule:#{schedule_id}:dispatch-token"

    assert {:ok, _schedule} =
             RedisStore.persist_schedule(schedule_id, %{
               "kind" => "event",
               "status" => "active",
               "enabled" => true,
               "marker" => "initial"
             })

    assert {:ok, first_lease} = RedisStore.acquire_fenced_lease(lease_name, "owner-a", 20)
    Process.sleep(30)
    assert {:ok, second_lease} = RedisStore.acquire_fenced_lease(lease_name, "owner-b", 1_000)

    assert {:ok, dispatch_lease} =
             RedisStore.acquire_fenced_lease(dispatch_lease_name, "dispatcher", 1_000)

    assert :ok =
             RedisStore.release_fenced_lease(
               dispatch_lease_name,
               "dispatcher",
               dispatch_lease["epoch"]
             )

    assert {:error, :not_owner} =
             RedisStore.persist_schedule_fenced(
               schedule_id,
               %{"marker" => "stale"},
               lease_name,
               "owner-a",
               first_lease["epoch"]
             )

    assert {:ok, _schedule} =
             RedisStore.persist_schedule_fenced(
               schedule_id,
               %{"marker" => "current"},
               lease_name,
               "owner-b",
               second_lease["epoch"]
             )

    assert {:ok, %{"marker" => "current"}} = RedisStore.fetch_schedule(schedule_id)

    assert {:error, :not_owner} =
             RedisStore.delete_schedule_fenced(
               schedule_id,
               lease_name,
               "owner-a",
               first_lease["epoch"]
             )

    assert :ok =
             RedisStore.delete_schedule_fenced(
               schedule_id,
               lease_name,
               "owner-b",
               second_lease["epoch"]
             )

    assert {:error, :not_owner} =
             RedisStore.release_fenced_lease(lease_name, "owner-b", second_lease["epoch"])

    assert {:ok, []} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "schedule:#{schedule_id}:*"])
             ])
  end

  test "retention reclaims missing schedule indexes and leases but preserves corrupt records", %{
    namespace: namespace
  } do
    suspend_retention()
    missing_id = "missing-schedule-#{System.unique_integer([:positive])}"
    corrupt_id = "corrupt-schedule-#{System.unique_integer([:positive])}"

    schedule = %{
      "kind" => "delayed",
      "status" => "active",
      "enabled" => true,
      "next_run_at" => "2030-01-01T00:00:00Z"
    }

    assert {:ok, _schedule} = RedisStore.persist_schedule(missing_id, schedule)
    assert {:ok, _schedule} = RedisStore.persist_schedule(corrupt_id, schedule)

    assert {:ok, _lease} =
             RedisStore.acquire_fenced_lease("schedule:#{missing_id}:state", "owner", 5_000)

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["schedule", missing_id])
             ])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["schedule", corrupt_id]),
               "not-json"
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_schedules == [missing_id]
    assert result.stale_schedule_count == 1

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["schedules"]),
               missing_id
             ])

    assert {:ok, nil} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "ZSCORE",
               redis_key(namespace, ["schedule", "due"]),
               missing_id
             ])

    assert {:ok, []} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "schedule:#{missing_id}:*"])
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["schedules"]),
               corrupt_id
             ])

    assert {:ok, score} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "ZSCORE",
               redis_key(namespace, ["schedule", "due"]),
               corrupt_id
             ])

    assert is_binary(score)
  end

  test "job deletion reclaims fenced lease epochs", %{namespace: namespace} do
    job_id = "lease-cleanup-job-#{System.unique_integer([:positive])}"
    lease_name = "job:#{job_id}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "runtime", 1_000)
    assert :ok = RedisStore.release_fenced_lease(lease_name, "runtime", lease["epoch"])

    assert {:ok, [_epoch_key]} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "job:#{job_id}*"])
             ])

    assert :ok = RedisStore.delete_job(job_id)

    assert {:ok, []} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "job:#{job_id}*"])
             ])
  end

  test "ephemeral fenced lease release removes its epoch", %{namespace: namespace} do
    lease_name = "ephemeral-#{System.unique_integer([:positive])}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "dispatcher", 1_000)

    assert :ok =
             RedisStore.release_ephemeral_fenced_lease(
               lease_name,
               "dispatcher",
               lease["epoch"]
             )

    assert {:ok, []} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "#{lease_name}*"])
             ])
  end

  test "durable write acknowledgement reports timeout when not enough replicas are available" do
    required_replicas = 99
    Application.put_env(:mirror_neuron, :redis_wait_replicas, required_replicas)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 1)
    job_id = "wait-timeout-#{System.unique_integer([:positive])}"

    assert {:error, {:redis_replication_wait_timeout, acknowledgements, ^required_replicas}} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running"
             })

    assert is_integer(acknowledgements)
    assert acknowledgements < required_replicas
  end

  test "bundle archive and node state round-trip nested data" do
    fingerprint = "bundle-#{System.unique_integer([:positive])}"

    assert {:ok, archive} =
             RedisStore.persist_bundle_archive(fingerprint, %{
               "graph_id" => "graph",
               "files" => [%{"path" => "payload/main.py", "data" => "print(1)"}]
             })

    assert archive["fingerprint"] == fingerprint
    assert {:ok, fetched} = RedisStore.fetch_bundle_archive(fingerprint)
    assert get_in(fetched, ["files", Access.at(0), "path"]) == "payload/main.py"

    assert {:ok, state} =
             RedisStore.persist_node_state("node-a@test", %{
               status: :healthy,
               capacities: %{default: 2},
               flags: [:runtime]
             })

    assert state["status"] == :healthy
    assert state["capacities"]["default"] == 2
    assert state["flags"] == [:runtime]

    assert {:ok, fetched_state} = RedisStore.fetch_node_state("node-a@test")
    assert fetched_state["status"] == "healthy"
    assert fetched_state["flags"] == ["runtime"]

    assert {:ok, states} = RedisStore.list_node_states()
    assert Enum.any?(states, &(&1["node"] == "node-a@test"))
  end

  test "node state listing compacts missing indexes but preserves unreadable state", %{
    namespace: namespace
  } do
    missing_node = "missing-node@test"
    corrupt_node = "corrupt-node@test"

    assert {:ok, 2} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["nodes"]),
               missing_node,
               corrupt_node
             ])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["node", corrupt_node, "state"]),
               "not-json"
             ])

    assert {:ok, states} = RedisStore.list_node_states()
    refute Enum.any?(states, &(&1["node"] in [missing_node, corrupt_node]))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["nodes"]),
               missing_node
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["nodes"]),
               corrupt_node
             ])
  end

  test "recovery evals can be persisted, listed, and updated" do
    eval_id = "eval-#{System.unique_integer([:positive])}"

    assert {:ok, eval} =
             RedisStore.persist_recovery_eval(eval_id, %{
               "job_id" => "job-a",
               "trigger" => "node_down",
               "status" => "pending",
               "attempt" => 0,
               "affected_agents" => ["worker"],
               "job" => %{
                 "job_id" => "job-a",
                 "manifest" => %{"payload" => String.duplicate("x", 1024)}
               },
               "manifest" => %{"payload" => String.duplicate("y", 1024)},
               "runtime_logs" => ["noisy runtime line"]
             })

    assert eval["eval_id"] == eval_id
    assert eval["status"] == "pending"
    refute Map.has_key?(eval, "job")
    refute Map.has_key?(eval, "manifest")
    refute Map.has_key?(eval, "runtime_logs")

    assert {:ok, fetched} = RedisStore.fetch_recovery_eval(eval_id)
    assert fetched["affected_agents"] == ["worker"]
    refute Map.has_key?(fetched, "job")
    refute Map.has_key?(fetched, "manifest")
    refute Map.has_key?(fetched, "runtime_logs")

    assert {:ok, evals} = RedisStore.list_recovery_evals()
    assert Enum.any?(evals, &(&1["eval_id"] == eval_id))

    assert {:ok, updated} =
             RedisStore.update_recovery_eval(eval_id, %{
               "status" => "blocked",
               "wait_until" => "2030-01-01T00:00:00Z"
             })

    assert updated["status"] == "blocked"
    assert updated["wait_until"] == "2030-01-01T00:00:00Z"
    refute Map.has_key?(updated, "job")
  end

  test "bundle archive store reuses an existing fingerprint archive" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_archive_cache_#{System.unique_integer([:positive])}"
      )

    cache_dir = Path.join(tmp_dir, "cache")
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_BUNDLE_CACHE_DIR", cache_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
    end)

    bundle_dir = create_bundle(tmp_dir, "cached_archive")
    assert {:ok, fingerprint} = Fingerprint.compute(bundle_dir)

    assert {:ok, _archive} =
             RedisStore.persist_bundle_archive(fingerprint, %{
               "graph_id" => "cached_archive",
               "total_bytes" => 123,
               "files" => archive_files(bundle_dir)
             })

    assert {:ok, bundle} = JobBundle.load(bundle_dir)
    assert {:ok, result} = Archive.store(bundle)

    assert result.storage == "redis"
    assert result.total_bytes == 123
    assert File.exists?(Path.join([cache_dir, fingerprint, "manifest.json"]))
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp redis_key(namespace, parts), do: Enum.join([namespace | parts], ":")

  defp suspend_retention do
    case Process.whereis(MirrorNeuron.Persistence.Retention) do
      retention when is_pid(retention) ->
        :sys.suspend(retention)

        on_exit(fn ->
          if Process.alive?(retention), do: :sys.resume(retention)
        end)

      nil ->
        :ok
    end
  end

  defp assert_service_instance_reclaimed(namespace, instance_id, service) do
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

  defp assert_deployment_membership(
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

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end

  defp create_bundle(base_dir, graph_id) do
    bundle_dir = Path.join(base_dir, graph_id)
    payloads_dir = Path.join(bundle_dir, "payloads")

    File.mkdir_p!(payloads_dir)

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
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

  defp archive_files(bundle_dir) do
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
