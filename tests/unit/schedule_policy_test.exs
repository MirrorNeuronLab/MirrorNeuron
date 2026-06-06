defmodule MirrorNeuron.Runtime.SchedulePolicyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.SchedulePolicy

  test "normalizes periodic schedules and computes next run" do
    now = ~U[2026-05-24 10:00:00Z]

    assert {:ok, schedule} =
             SchedulePolicy.normalize(%{"cron" => "5 10 * * *"}, nil, now: now)

    assert schedule["kind"] == "periodic"
    assert schedule["prohibit_overlap"] == true
    assert schedule["missed_policy"] == "skip"
    assert schedule["next_run_at"] == "2026-05-24T10:05:00Z"
    refute Map.has_key?(schedule, "retry_interval_ms")
  end

  test "normalizes delayed schedules from delay_ms" do
    now = ~U[2026-05-24 10:00:00Z]

    assert {:ok, schedule} =
             SchedulePolicy.normalize(%{"kind" => "delayed", "delay_ms" => 60_000}, nil, now: now)

    assert schedule["run_at"] == "2026-05-24T10:01:00.000Z"
    assert schedule["next_run_at"] == "2026-05-24T10:01:00.000Z"
    refute Map.has_key?(schedule, "retry_interval_ms")
  end

  test "normalizes resource wait schedules as active one-shot queue items" do
    now = ~U[2026-05-24 10:00:00Z]

    assert {:ok, schedule} =
             SchedulePolicy.normalize(
               %{"kind" => "resource_wait", "retry_interval_ms" => 5_000},
               nil,
               now: now
             )

    assert schedule["kind"] == "resource_wait"
    assert schedule["retry_interval_ms"] == 5_000
    assert schedule["next_run_at"] == "2026-05-24T10:00:00Z"
    assert [%{"reason" => "resource_wait"}] = SchedulePolicy.due_instances(schedule, now)
  end

  test "matches generic event triggers with payload filters" do
    assert {:ok, schedule} =
             SchedulePolicy.normalize(%{
               "kind" => "event",
               "trigger" => %{
                 "event_type" => "file_uploaded",
                 "filters" => %{"path" => %{"prefix" => "datasets/"}}
               }
             })

    assert SchedulePolicy.event_matches?(schedule, %{
             "event_type" => "file_uploaded",
             "payload" => %{"path" => "datasets/input.jsonl"}
           })

    refute SchedulePolicy.event_matches?(schedule, %{
             "event_type" => "file_uploaded",
             "payload" => %{"path" => "tmp/input.jsonl"}
           })
  end

  test "skip missed policy marks late cron windows missed" do
    schedule = %{
      "kind" => "periodic",
      "enabled" => true,
      "status" => "active",
      "next_run_at" => "2026-05-24T10:00:00Z",
      "missed_policy" => "skip",
      "missed_grace_ms" => 1_000
    }

    assert SchedulePolicy.missed?(schedule, ~U[2026-05-24 10:00:02Z])
  end
end
