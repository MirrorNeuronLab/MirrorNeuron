defmodule MirrorNeuron.Runtime.RunClockTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.RunClock

  defp step(old, status, seconds, session \\ "one") do
    current = %{
      "status" => status,
      "updated_at" => "2026-09-29T12:00:#{String.pad_leading(to_string(seconds), 2, "0")}Z",
      "clock_session" => session
    }

    Map.put(current, "running_time", RunClock.advance(old, current))
  end

  test "running intervals exclude queue and pause, with idempotent snapshots" do
    queued = step(%{}, "pending", 0)
    running = step(queued, "running", 10)
    paused = step(running, "paused", 20)
    resumed = step(paused, "running", 30)
    done = step(resumed, "completed", 40)

    assert done["running_time"] == %{
             "accumulated_ms" => 20_000,
             "active_since" => nil,
             "complete" => true
           }

    assert step(done, "completed", 50)["running_time"] == done["running_time"]
  end

  test "restart excludes unobserved downtime and marks coverage partial" do
    running = %{} |> step("pending", 0) |> step("running", 1) |> step("running", 10)
    recovered = step(running, "pending", 30, "two")
    assert recovered["running_time"]["accumulated_ms"] == 9_000
    refute recovered["running_time"]["complete"]
    assert step(recovered, "cancelled", 40, "two")["running_time"]["active_since"] == nil
  end

  test "historical snapshots are not invented as complete intervals" do
    old = %{"status" => "running", "updated_at" => "2026-09-29T12:00:00Z"}
    result = step(old, "paused", 10)
    refute result["running_time"]["complete"]
    assert result["running_time"]["accumulated_ms"] == 0
  end

  test "a paused service can resume in another coordinator without counting the pause" do
    paused = %{} |> step("pending", 0) |> step("running", 1) |> step("paused", 10)
    resumed = step(paused, "running", 30, "two")
    cancelled = step(resumed, "cancelled", 40, "two")
    assert cancelled["running_time"]["accumulated_ms"] == 19_000
    assert cancelled["running_time"]["complete"]
  end
end
