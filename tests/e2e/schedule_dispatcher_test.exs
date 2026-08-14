defmodule MirrorNeuron.Runtime.ScheduleDispatcherTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.ScheduleDispatcher

  setup do
    unique = "schedule_test_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:mirror_neuron, :redis_namespace)
    Application.put_env(:mirror_neuron, :redis_namespace, unique)

    on_exit(fn ->
      _ = MirrorNeuron.Runtime.cleanup_jobs(all: true)
      cleanup_namespace(unique)
      Application.put_env(:mirror_neuron, :redis_namespace, previous)
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

  test "dispatch prunes terminal and missing jobs from active schedule state" do
    manifest = manifest("active_job_pruning")
    terminal_job_id = "terminal-schedule-job-#{System.unique_integer([:positive])}"
    missing_job_id = "missing-schedule-job-#{System.unique_integer([:positive])}"

    assert {:ok, schedule} =
             ScheduleDispatcher.create_schedule(manifest, %{
               "kind" => "event",
               "trigger" => %{"event_type" => "prune-active-jobs"}
             })

    assert {:ok, _job} =
             RedisStore.persist_terminal_job(terminal_job_id, %{"status" => "completed"}, %{
               "graph_id" => "terminal_schedule_job",
               "job_name" => "terminal schedule job"
             })

    assert {:ok, _schedule} =
             RedisStore.persist_schedule(
               schedule["schedule_id"],
               Map.put(schedule, "active_job_ids", [terminal_job_id, missing_job_id])
             )

    assert {:ok, %{dispatched: 1}} = ScheduleDispatcher.emit_event("prune-active-jobs")
    assert {:ok, updated} = RedisStore.fetch_schedule(schedule["schedule_id"])
    assert [new_job_id] = updated["active_job_ids"]
    refute new_job_id in [terminal_job_id, missing_job_id]
  end

  test "concurrent event dispatches retain every schedule update" do
    dispatch_count = 12

    assert {:ok, schedule} =
             ScheduleDispatcher.create_schedule(manifest("concurrent_dispatch"), %{
               "kind" => "event",
               "trigger" => %{"event_type" => "concurrent-dispatch"}
             })

    results =
      1..dispatch_count
      |> Task.async_stream(
        fn sequence ->
          ScheduleDispatcher.emit_event(
            "concurrent-dispatch",
            %{"sequence" => sequence},
            event_id: "concurrent-event-#{sequence}"
          )
        end,
        max_concurrency: dispatch_count,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %{dispatched: 1}}} -> true
             _result -> false
           end)

    assert {:ok, updated} = RedisStore.fetch_schedule(schedule["schedule_id"])
    assert get_in(updated, ["counters", "dispatched"]) == dispatch_count
    assert length(updated["dispatches"]) == dispatch_count

    assert updated["dispatches"]
           |> Enum.map(& &1["job_id"])
           |> Enum.uniq()
           |> length() == dispatch_count
  end

  defp manifest(graph_id) do
    %{
      "apiVersion" => "mn.workflow/v2",
      "manifest_version" => "1.0",
      "graph_id" => "schedule_#{graph_id}",
      "job_name" => "schedule #{graph_id}",
      "type" => "batch",
      "flow" => %{
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
            "config" => %{
              "complete_on_message" => true,
              "terminal_sink" => true,
              "complete_run" => true
            }
          }
        ],
        "edges" => [
          %{"from_node" => "root", "to_node" => "sink", "message_type" => "done"}
        ]
      },
      "entrypoints" => ["root"],
      "policies" => %{"recovery_mode" => "manual_recover"}
    }
  end

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end
end
