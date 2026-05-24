defmodule MirrorNeuron.Runtime.ScheduleDispatcherTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.ScheduleDispatcher

  setup do
    unique = "schedule_test_#{System.unique_integer([:positive])}"
    previous = System.get_env("MN_REDIS_NAMESPACE")
    System.put_env("MN_REDIS_NAMESPACE", unique)

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_REDIS_NAMESPACE", previous),
        else: System.delete_env("MN_REDIS_NAMESPACE")
    end)

    :ok
  end

  test "creates delayed schedules and stores them in Redis" do
    manifest = manifest("delayed")

    assert {:ok, schedule} =
             ScheduleDispatcher.create_schedule(manifest, %{
               "kind" => "delayed",
               "run_at" => "2026-05-24T10:00:00Z"
             })

    assert schedule["kind"] == "delayed"
    assert schedule["next_run_at"] == "2026-05-24T10:00:00Z"
    assert {:ok, fetched} = RedisStore.fetch_schedule(schedule["schedule_id"])
    assert fetched["schedule_id"] == schedule["schedule_id"]
  end

  test "event emission dispatches matching event schedules once" do
    manifest = manifest("event")

    assert {:ok, schedule} =
             ScheduleDispatcher.create_schedule(manifest, %{
               "kind" => "event",
               "trigger" => %{"event_type" => "demo", "filters" => %{"topic" => "alpha"}}
             })

    assert {:ok, result} = ScheduleDispatcher.emit_event("demo", %{"topic" => "alpha"})

    assert result.dispatched == 1
    assert {:ok, updated} = RedisStore.fetch_schedule(schedule["schedule_id"])
    assert [%{"job_id" => job_id} | _] = updated["dispatches"]
    assert is_binary(job_id)
  end

  defp manifest(graph_id) do
    %{
      "manifest_version" => "1.0",
      "graph_id" => "schedule_#{graph_id}",
      "job_name" => "schedule #{graph_id}",
      "type" => "batch",
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "done"}
        },
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "sink", "message_type" => "done"}
      ],
      "entrypoints" => ["root"],
      "policies" => %{"recovery_mode" => "manual_recover"}
    }
  end
end
