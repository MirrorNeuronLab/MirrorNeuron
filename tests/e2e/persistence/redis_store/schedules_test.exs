defmodule MirrorNeuron.Persistence.RedisStore.SchedulesTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore

  test "trigger events use only the bounded list", %{
    namespace: namespace
  } do
    suspend_retention()
    event_id = "trigger-event-#{System.unique_integer([:positive])}"

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
    suspend_background_schedule_sweeps()
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

  test "schedule reads reclaim missing indexes and leases before retention", %{
    namespace: namespace
  } do
    suspend_background_schedule_sweeps()
    schedule_id = "missing-schedule-read-#{System.unique_integer([:positive])}"

    assert {:ok, _schedule} =
             RedisStore.persist_schedule(schedule_id, %{
               "kind" => "delayed",
               "status" => "active",
               "enabled" => true,
               "next_run_at" => "2030-01-01T00:00:00Z"
             })

    assert {:ok, _lease} =
             RedisStore.acquire_fenced_lease("schedule:#{schedule_id}:state", "owner", 5_000)

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["schedule", schedule_id])
             ])

    assert {:ok, []} = RedisStore.list_schedules()

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["schedules"]),
               schedule_id
             ])

    assert {:ok, nil} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "ZSCORE",
               redis_key(namespace, ["schedule", "due"]),
               schedule_id
             ])

    assert {:ok, []} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "schedule:#{schedule_id}:*"])
             ])
  end
end
