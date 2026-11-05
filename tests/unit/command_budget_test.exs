defmodule MirrorNeuron.Runner.CommandBudgetTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.CommandBudget

  defp new, do: CommandBudget.new(300_000, %{"MN_WORKFLOW_ATTEMPT_ID" => "attempt"}, 0)

  defp preparation(id, timeout \\ 1_200_000),
    do: %{
      "preparation_id" => id,
      "kind" => "model",
      "timeout_ms" => timeout,
      "attempt_id" => "attempt"
    }

  defp event(budget, type, payload, at), do: CommandBudget.observe(budget, type, payload, at)
  defp remaining(budget, at), do: elem(CommandBudget.remaining(budget, at), 0)

  defp progress(sequence, extra \\ %{}),
    do: Map.merge(%{"pid" => 1, "source" => "agent", "progress_sequence" => sequence}, extra)

  test "sequential preparation excludes only its actual intervals, never the gap" do
    budget = new() |> event("runtime_preparation_started", preparation("first"), 10_000)
    budget = event(budget, "runtime_preparation_finished", preparation("first"), 110_000)
    budget = event(budget, "runtime_preparation_started", preparation("second"), 210_000)
    budget = event(budget, "runtime_preparation_finished", preparation("second"), 510_000)
    assert remaining(budget, 699_999) == 1
    assert remaining(budget, 700_000) == 0
  end

  test "nested preparation excludes its union once and expires at the owner's fixed bound" do
    budget = new() |> event("runtime_preparation_started", preparation("outer"), 10_000)
    budget = event(budget, "runtime_preparation_started", preparation("inner", 600_000), 20_000)
    budget = event(budget, "runtime_preparation_started", preparation("inner", 600_000), 300_000)
    assert remaining(budget, 619_999) > 0
    assert remaining(budget, 620_000) == 0
    late = event(budget, "runtime_preparation_finished", preparation("inner"), 620_001)
    assert remaining(late, 620_001) == 0
  end

  test "fresh progress extends runner inactivity, repeated automatic beacons do not" do
    budget = event(new(), "agent_beacon", progress(1), 299_000)
    assert remaining(budget, 500_000) == 99_000
    budget = event(budget, "agent_beacon", progress(1), 598_000)
    assert remaining(budget, 599_000) == 0
  end

  test "bounded waits, old-attempt and runtime-generated beacons cannot renew forever" do
    wait = progress(1, %{"wait_id" => "request", "wait_timeout_ms" => 900_000})
    budget = event(new(), "agent_beacon", wait, 10_000)
    assert remaining(budget, 900_000) == 310_000
    budget = event(budget, "agent_beacon", Map.put(wait, "progress_sequence", 2), 1_000_000)
    assert remaining(budget, 1_210_000) == 0

    assert remaining(
             event(new(), "agent_beacon", progress(10, %{"attempt_id" => "old"}), 299_000),
             300_000
           ) == 0

    assert remaining(
             event(new(), "agent_beacon", progress(10, %{"source" => "runtime"}), 299_000),
             300_000
           ) == 0
  end

  test "no execution budget still has a bounded preparation watchdog" do
    budget = CommandBudget.new(nil, %{"MN_WORKFLOW_ATTEMPT_ID" => "attempt"}, 0)
    assert remaining(budget, 900_000) == :infinity
    budget = event(budget, "runtime_preparation_started", preparation("setup", 1_000), 10)
    assert remaining(budget, 1_010) == 0
  end
end
