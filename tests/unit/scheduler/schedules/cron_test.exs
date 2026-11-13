defmodule MirrorNeuron.Scheduler.Schedules.CronTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Scheduler.Schedules.Cron

  for expression <- [
        "",
        "* * * *",
        "* * * * * *",
        "60 * * * *",
        "* 24 * * *",
        "* * 0 * *",
        "* * * 13 *",
        "* * * * 8",
        "*/0 * * * *",
        "5-2 * * * *",
        "@unknown"
      ] do
    test "rejects invalid cron #{inspect(expression)}" do
      assert {:error, _} = Cron.parse_cron(unquote(expression))
      assert {:error, _} = Cron.next_cron_after(unquote(expression), ~U[2026-11-12 12:00:00Z])
    end
  end

  test "steps, ranges and lists advance to the next eligible minute" do
    assert {:ok, ~U[2026-11-12 17:00:00Z]} =
             Cron.next_cron_after("*/15 9-17 * * 1-5", ~U[2026-11-12 16:59:59Z])

    assert {:ok, ~U[2026-11-12 17:30:00Z]} =
             Cron.next_cron_after("0,30 * * * *", ~U[2026-11-12 17:00:00Z])
  end

  test "aliases cross the year boundary and never repeat the current minute" do
    for expression <- ["@yearly", "@annually", "0 0 1 1 *"] do
      assert {:ok, ~U[2027-01-01 00:00:00Z]} =
               Cron.next_cron_after(expression, ~U[2026-12-31 23:59:59Z])
    end

    assert {:ok, ~U[2026-11-12 12:01:00Z]} =
             Cron.next_cron_after("* * * * *", ~U[2026-11-12 12:00:00Z])
  end

  test "Sunday accepts zero or seven and constrained day fields use OR semantics" do
    for weekday <- [0, 7] do
      assert {:ok, ~U[2026-11-15 00:00:00Z]} =
               Cron.next_cron_after("0 0 * * #{weekday}", ~U[2026-11-14 00:00:00Z])
    end

    assert {:ok, ~U[2026-11-13 00:00:00Z]} =
             Cron.next_cron_after("0 0 15 * 5", ~U[2026-11-12 00:00:00Z])

    assert {:ok, ~U[2026-11-15 00:00:00Z]} =
             Cron.next_cron_after("0 0 15 * 5", ~U[2026-11-14 00:00:00Z])
  end
end
