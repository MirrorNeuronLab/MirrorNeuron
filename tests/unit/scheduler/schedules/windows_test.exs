defmodule MirrorNeuron.Scheduler.Schedules.WindowsTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Scheduler.Schedules.Windows

  @now ~U[2026-11-12 12:00:00Z]

  defp schedule(id, finish, overrides \\ %{}) do
    Map.merge(
      %{
        "schedule_id" => id,
        "job_id" => "job",
        "target_type" => "service",
        "window" => %{"end_action" => "pause"},
        "dispatches" => [
          %{
            "dispatch_id" => id,
            "run_id" => "run",
            "status" => "submitted",
            "window_end_at" => finish
          }
        ]
      },
      overrides
    )
  end

  test "a service stays active until its last overlapping window closes" do
    first = schedule("first", "2026-11-12T11:59:00Z")
    last = schedule("last", "2026-11-12T12:01:00Z")
    assert [{^first, _, false}] = Windows.due_closures([first, last], @now)

    assert [{^first, _, false}, {^last, _, true}] =
             Windows.due_closures([first, last], DateTime.add(@now, 60))
  end

  test "a non-expiring window keeps the same service run active" do
    due = schedule("due", "2026-11-12T12:00:00Z")
    open = schedule("open", nil)
    assert [{^due, _, false}] = Windows.due_closures([due, open], @now)
  end

  test "windows for different jobs or different runs do not keep a due run alive" do
    due = schedule("due", "2026-11-12T12:00:00Z")
    another_job = schedule("other-job", nil, %{"job_id" => "other"})

    another_run =
      put_in(schedule("other-run", nil), ["dispatches", Access.at(0), "run_id"], "another-run")

    assert [{^due, _, true}] = Windows.due_closures([due, another_job, another_run], @now)
  end

  test "closed windows and windows without an end action are not closed again" do
    closed =
      put_in(
        schedule("closed", "2026-11-12T12:00:00Z"),
        ["dispatches", Access.at(0), "status"],
        "window_closed"
      )

    no_action =
      schedule("no-action", "2026-11-12T12:00:00Z", %{"window" => %{"end_action" => "none"}})

    assert [] = Windows.due_closures([closed, no_action], @now)
  end

  test "batch windows remain independent of service overlap decisions" do
    batch =
      schedule("batch", "2026-11-12T12:00:00Z", %{
        "target_type" => "batch",
        "window" => %{"end_action" => "cancel"}
      })

    assert [{^batch, _, false}] = Windows.due_closures([batch], @now)
  end
end
