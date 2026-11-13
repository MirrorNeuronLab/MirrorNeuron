defmodule MirrorNeuron.Scheduler.Schedules.OccurrenceIdentityTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.ScheduleOccurrence

  test "replayed events retain identity when delivery time changes" do
    schedule = %{"schedule_id" => "schedule"}

    event = %{
      "reason" => "event",
      "event" => %{"event_id" => "event-1"},
      "scheduled_for" => "2026-11-12T12:00:00Z"
    }

    token = ScheduleOccurrence.token(schedule, event)

    assert token ==
             ScheduleOccurrence.token(
               schedule,
               Map.put(event, "scheduled_for", "2026-11-12T12:05:00Z")
             )

    refute token ==
             ScheduleOccurrence.token(schedule, put_in(event, ["event", "event_id"], "event-2"))

    refute token == ScheduleOccurrence.token(%{"schedule_id" => "different"}, event)
  end

  test "periodic occurrences use their scheduled time and trigger identity" do
    schedule = %{"schedule_id" => "schedule"}
    instance = %{"reason" => "periodic", "scheduled_for" => "2026-11-12T12:00:00Z"}
    token = ScheduleOccurrence.token(schedule, instance)
    assert token == ScheduleOccurrence.token(schedule, instance)

    refute token ==
             ScheduleOccurrence.token(
               schedule,
               Map.put(instance, "scheduled_for", "2026-11-12T12:01:00Z")
             )

    refute token == ScheduleOccurrence.token(schedule, Map.put(instance, "reason", "manual"))
  end
end
