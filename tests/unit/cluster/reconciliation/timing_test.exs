defmodule MirrorNeuron.Cluster.Reconciler.TimingTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Cluster.Reconciler.{EvaluationRecords, Timing}

  test "large persisted attempt counts remain bounded without overflowing" do
    before = DateTime.utc_now()
    until = Timing.retry_wait_until(%{"attempt" => 10_000}, retry_base_ms: 5, retry_max_ms: 50)
    assert {:ok, deadline, 0} = DateTime.from_iso8601(until)
    assert DateTime.diff(deadline, before, :millisecond) >= 50
    assert DateTime.diff(deadline, DateTime.utc_now(), :millisecond) <= 50
  end

  test "zero delay remains immediate for arbitrarily many attempts" do
    until = Timing.retry_wait_until(%{"attempt" => 10_000}, retry_base_ms: 0, retry_max_ms: 50)
    assert Timing.wait_due?(until)
  end

  test "persisted attempts parse only complete non-negative integers" do
    for invalid <- [nil, -1, "-1", "2later", %{}, []] do
      assert Timing.recovery_eval_attempt(%{"attempt" => invalid}) == 0
    end

    assert Timing.recovery_eval_attempt(%{"attempt" => "12"}) == 12
  end

  test "running and terminal evaluations never become due" do
    for status <- ["running", "complete", "failed"] do
      refute Timing.due_eval?(%{"status" => status, "wait_until" => nil})
    end

    future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    refute Timing.due_eval?(%{"status" => "blocked", "wait_until" => future})
    assert Timing.due_eval?(%{"status" => "pending"})
  end

  test "repeated recovery preserves only the latest twenty history entries" do
    history = Enum.map(1..100, &%{"reason" => to_string(&1)})

    updated =
      EvaluationRecords.append_eval_history(%{"history" => history}, "blocked", "capacity")

    assert length(updated) == 20
    assert hd(updated)["reason"] == "82"
    assert List.last(updated)["reason"] == "capacity"
    assert List.last(updated)["status"] == "blocked"
  end
end
