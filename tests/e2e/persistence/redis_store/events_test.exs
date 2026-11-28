defmodule MirrorNeuron.Persistence.RedisStore.EventsTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.EventBus

  test "activity cursors survive trimming and migration of existing events", %{namespace: ns} do
    job_id = "legacy-activity"
    key = redis_key(ns, ["job", job_id, "events"])
    {:ok, 2} = Redix.command(MirrorNeuron.Redis.Connection, ["RPUSH", key, "{}", "{}"])
    activity = &MirrorNeuron.Persistence.RedisStore.Events.activity_page(job_id, &1, 2)
    assert {:ok, [%{"sequence" => 1}, %{"sequence" => 2}]} = activity.(0)
    Application.put_env(:mirror_neuron, :event_max_count, 2)

    for n <- 3..5 do
      assert {:ok, _} = RedisStore.append_event(job_id, %{"type" => "item", "n" => n})
    end

    assert {:error, :activity_replay_gap} = activity.(2)
    assert {:ok, [%{"sequence" => 4}, %{"sequence" => 5, "_journal_head" => 5}]} = activity.(3)
    assert {:ok, []} = activity.(5)
    assert {:error, :activity_replay_gap} = activity.(6)
  end

  test "a Redis command error inside a trigger transaction reaches the caller", %{
    namespace: namespace
  } do
    key = redis_key(namespace, ["trigger", "events"])
    assert {:ok, "OK"} = Redix.command(MirrorNeuron.Redis.Connection, ["SET", key, "wrong type"])

    assert {:error, reason} =
             MirrorNeuron.Persistence.RedisStore.append_trigger_event("event-1", %{
               "type" => "ready"
             })

    assert reason =~ "WRONGTYPE"
    assert {:ok, "wrong type"} = Redix.command(MirrorNeuron.Redis.Connection, ["GET", key])
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
end
