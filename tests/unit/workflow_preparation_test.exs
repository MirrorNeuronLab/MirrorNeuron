defmodule MirrorNeuron.Runtime.WorkflowPreparationTest do
  use ExUnit.Case, async: true

  defp reconcile(state, now) do
    {state, events, actions} = MirrorNeuron.Runtime.WorkflowLedger.reconcile(state, now)

    Enum.reduce(actions, {state, events, []}, fn
      {:inspect_step, id, token, agents}, {state, events, actions} ->
        {state, inspected, resolved} =
          MirrorNeuron.Runtime.WorkflowLedger.inspection_result(
            state,
            id,
            token,
            Map.new(agents, &{&1, "alive"}),
            now
          )

        {state, events ++ inspected, actions ++ resolved}

      action, {state, events, actions} ->
        {state, events, actions ++ [action]}
    end)
  end

  alias MirrorNeuron.Runtime.{WorkflowLedger, WorkflowPreparation}

  defp at(seconds),
    do:
      DateTime.from_unix!(1_800_000_000_000 + seconds * 1000, :millisecond)
      |> DateTime.to_iso8601()

  defp step(id \\ "plan", agent \\ "planner") do
    %{
      "id" => id,
      "status" => "running",
      "agent_ids" => [agent],
      "run" => agent,
      "timeout_seconds" => 300,
      "beacon_timeout_ms" => 300_000,
      "heartbeat_uses_execution_budget" => true,
      "deadline_at" => at(300),
      "heartbeat_deadline_at" => at(300),
      "attempt_count" => 1,
      "max_attempts" => 1,
      "attempts" => [],
      "current_attempt" => %{
        "attempt_id" => id <> ":attempt:1",
        "attempt" => 1,
        "agent_id" => agent,
        "started_at" => at(0),
        "deadline_at" => at(300),
        "status" => "running"
      }
    }
  end

  defp state do
    %{
      "enabled" => true,
      "status" => "running",
      "steps" => %{"plan" => step()},
      "step_order" => ["plan"],
      "agent_to_step" => %{"planner" => "plan"},
      "edges" => [],
      "messages" => %{}
    }
  end

  defp payload(id \\ "setup", timeout \\ 1_200_000) do
    %{
      "preparation_id" => id,
      "timeout_ms" => timeout,
      "kind" => "model",
      "step_id" => "plan",
      "attempt_id" => "plan:attempt:1"
    }
  end

  defp event(state, type, payload, seconds, agent \\ "planner") do
    {state, [], []} =
      WorkflowLedger.on_agent_event(
        state,
        agent,
        "runtime_preparation_" <> type,
        payload,
        at(seconds)
      )

    state
  end

  test "cold preparation longer than the step allowance leaves actual work its remaining time" do
    state = state() |> event("started", payload(), 10)
    {state, [], []} = reconcile(state, at(1_000))
    assert state["steps"]["plan"]["status"] == "running"
    state = event(state, "finished", payload(), 1_010)
    assert state["steps"]["plan"]["deadline_at"] == at(1_300)
    assert state["steps"]["plan"]["current_attempt"]["deadline_at"] == at(1_300)
    {state, [], []} = reconcile(state, at(1_299))
    {state, _, actions} = reconcile(state, at(1_300))
    assert state["steps"]["plan"]["status"] == "failed"
    assert Enum.any?(actions, &match?({:terminate_agent, _, _}, &1))
  end

  test "overlapping and nested preparations are excluded once and duplicate starts do not renew" do
    state = state() |> event("started", payload("outer"), 10)
    state = event(state, "started", payload("inner"), 20)
    state = event(state, "started", payload("outer"), 30)
    state = event(state, "finished", payload("inner"), 40)
    state = event(state, "finished", payload("outer"), 50)
    assert state["steps"]["plan"]["deadline_at"] == at(340)
    assert state["steps"]["plan"]["preparation"]["active"] == %{}
    assert event(state, "finished", payload("outer"), 60) == state
    assert event(state, "started", payload("outer"), 70) == state
  end

  test "stalled setup has a fixed deadline even when starts and progress repeat" do
    state = state() |> event("started", payload("setup", 20_000), 10)
    state = event(state, "started", payload("setup", 20_000), 20)
    state = event(state, "finished", payload("setup", 20_000), 30)
    {state, _, _} = reconcile(state, at(30))
    assert state["steps"]["plan"]["status"] == "failed"
    assert state["steps"]["plan"]["terminal_reason"] =~ "preparation deadline"
  end

  test "late, invalid, foreign and old-attempt events cannot create an exclusion" do
    for invalid <- [
          Map.put(payload(), "timeout_ms", 0),
          Map.put(payload(), "timeout_ms", 86_400_001),
          Map.put(payload(), "timeout_ms", "1200"),
          Map.put(payload(), "kind", "inference"),
          Map.put(payload(), "attempt_id", "plan:attempt:0")
        ] do
      assert event(state(), "started", invalid, 10) == state()
    end

    assert event(state(), "started", payload(), 10, "foreign") == state()
    assert event(state(), "started", payload(), 301) == state()
  end

  test "explicit liveness continues to fail during setup" do
    original = state()
    original = put_in(original, ["steps", "plan", "heartbeat_uses_execution_budget"], false)
    original = put_in(original, ["steps", "plan", "heartbeat_deadline_at"], at(15))
    state = event(original, "started", payload(), 10)
    {state, _, _} = reconcile(state, at(16))
    assert state["steps"]["plan"]["terminal_reason"] =~ "heartbeat"
  end

  test "child setup excludes the same interval from the enclosing parent" do
    child = step("child", "child-worker") |> Map.put("parent_step_id", "plan")
    state = state() |> put_in(["steps", "child"], child)
    state = put_in(state, ["agent_to_step", "child-worker"], "child")
    data = payload() |> Map.merge(%{"step_id" => "child", "attempt_id" => "child:attempt:1"})
    state = event(state, "started", data, 10, "child-worker")
    state = event(state, "finished", data, 110, "child-worker")
    assert state["steps"]["plan"]["deadline_at"] == at(400)
    assert state["steps"]["child"]["deadline_at"] == at(400)
  end

  test "snapshots retain setup ownership while pause retires stopped scopes without double accounting" do
    state = state() |> event("started", payload(), 10)
    restored = state |> Jason.encode!() |> Jason.decode!()
    {restored, [], []} = reconcile(restored, at(20))
    assert restored["steps"]["plan"]["deadline_at"] == at(310)
    {paused, _} = WorkflowLedger.pause(restored, at(30))
    assert paused["steps"]["plan"]["preparation"]["active"] == %{}
    assert event(paused, "started", payload("new"), 40) == paused
    {resumed, []} = WorkflowLedger.resume(paused, at(1_030))
    assert resumed["steps"]["plan"]["deadline_at"] == at(1_320)
    assert WorkflowPreparation.reset(resumed["steps"]["plan"])["preparation"] == nil
  end
end
