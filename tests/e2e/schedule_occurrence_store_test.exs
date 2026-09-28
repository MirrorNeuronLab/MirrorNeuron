defmodule MirrorNeuron.Persistence.ScheduleOccurrenceStoreTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Persistence.RedisStore

  setup do
    schedule_id = "occurrence-test-#{System.unique_integer([:positive])}"
    {:ok, _} = RedisStore.persist_schedule(schedule_id, %{"enabled" => false})
    lease_name = "schedule:#{schedule_id}:state"
    {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "test-owner", 30_000)
    lock = %{lease_name: lease_name, owner: "test-owner", lease: lease}
    on_exit(fn -> RedisStore.delete_schedule(schedule_id) end)
    %{schedule_id: schedule_id, lock: lock}
  end

  test "atomic reservation has one winner and survives a new state lease", %{
    schedule_id: id,
    lock: lock
  } do
    record = %{"run_id" => "scheduled-test", "status" => "reserved"}

    results =
      1..8
      |> Task.async_stream(fn _ ->
        RedisStore.reserve_schedule_occurrence(id, "token", record, lock)
      end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(results, &match?({:ok, :new, _}, &1)) == 1
    assert Enum.count(results, &match?({:ok, :existing, _}, &1)) == 7
    :ok = RedisStore.release_fenced_lease(lock.lease_name, lock.owner, lock.lease["epoch"])
    {:ok, lease} = RedisStore.acquire_fenced_lease(lock.lease_name, "next-owner", 30_000)
    next = %{lock | owner: "next-owner", lease: lease}

    assert {:ok, :existing, ^record} =
             RedisStore.reserve_schedule_occurrence(id, "token", record, next)

    assert {:error, :not_owner} =
             RedisStore.complete_schedule_occurrence(
               id,
               "token",
               Map.put(record, "status", "submitted"),
               lock
             )

    assert :ok =
             RedisStore.complete_schedule_occurrence(
               id,
               "token",
               Map.put(record, "status", "submitted"),
               next
             )

    assert {:ok, :existing, %{"status" => "submitted"}} =
             RedisStore.reserve_schedule_occurrence(id, "token", record, next)

    assert :ok =
             RedisStore.delete_schedule_fenced(
               id,
               next.lease_name,
               next.owner,
               next.lease["epoch"]
             )

    assert {:error, :not_owner} =
             RedisStore.reserve_schedule_occurrence(id, "token", record, next)
  end

  test "cannot complete a receipt for a different execution", %{schedule_id: id, lock: lock} do
    assert {:ok, :new, _} =
             RedisStore.reserve_schedule_occurrence(id, "token", %{"run_id" => "one"}, lock)

    assert {:error, :not_owner} =
             RedisStore.complete_schedule_occurrence(id, "token", %{"run_id" => "other"}, lock)
  end

  test "reconciles a persisted run after the dispatcher loses its lease", %{
    schedule_id: id,
    lock: lock
  } do
    metadata = %{"schedule_id" => id, "dispatch_id" => "recover-token"}

    start = fn run_id ->
      {:ok, _} =
        RedisStore.persist_job(run_id, %{
          "status" => "completed",
          "manifest" => %{"metadata" => %{"schedule_dispatch" => metadata}}
        })

      :ok = RedisStore.release_fenced_lease(lock.lease_name, lock.owner, lock.lease["epoch"])
      {:ok, %{run_id: run_id, status: "completed", action: "started"}}
    end

    assert {:error, :not_owner} =
             MirrorNeuron.Runtime.ScheduleOccurrence.run(
               %{"schedule_id" => id},
               metadata,
               lock,
               start
             )

    {:ok, lease} = RedisStore.acquire_fenced_lease(lock.lease_name, "restarted", 30_000)
    next = %{lock | owner: "restarted", lease: lease}

    assert {:ok, result} =
             MirrorNeuron.Runtime.ScheduleOccurrence.run(
               %{"schedule_id" => id},
               metadata,
               next,
               fn _ -> flunk("duplicate execution") end
             )

    assert result.run_id == "scheduled_recover-token"
    assert result.status == "completed"
    assert :ok = RedisStore.delete_job(result.run_id)

    assert {:ok, replay} =
             MirrorNeuron.Runtime.ScheduleOccurrence.run(
               %{"schedule_id" => id},
               metadata,
               next,
               fn _ -> flunk("duplicate after retention") end
             )

    assert replay.run_id == result.run_id
  end
end
