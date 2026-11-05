defmodule MirrorNeuron.Runtime.WorkflowSupervisionTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.{WorkflowLedger, WorkflowSupervision}

  defp at(seconds),
    do:
      DateTime.from_unix!(1_800_000_000_000 + round(seconds * 1000), :millisecond)
      |> DateTime.to_iso8601()

  defp step(id \\ "plan", agent \\ "planner") do
    %{
      "id" => id,
      "status" => "running",
      "run" => agent,
      "agent_ids" => [agent],
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
        "status" => "running"
      }
    }
  end

  defp state,
    do: %{
      "enabled" => true,
      "status" => "running",
      "steps" => %{"plan" => step()},
      "step_order" => ["plan"],
      "agent_to_step" => %{"planner" => "plan"},
      "edges" => [],
      "messages" => %{}
    }

  defp beacon(state, second, sequence, extra \\ %{}) do
    data =
      Map.merge(
        %{
          "source" => "agent",
          "agent_id" => "planner",
          "pid" => 7,
          "progress_sequence" => sequence,
          "attempt_id" => "plan:attempt:1"
        },
        extra
      )

    {state, _, []} =
      WorkflowLedger.on_agent_event(state, "planner", "agent_beacon", data, at(second))

    state
  end

  defp inspect_step(state, seconds \\ 300) do
    {state, events, [{:inspect_step, "plan", token, agents}]} =
      WorkflowLedger.reconcile(state, at(seconds))

    assert Enum.any?(events, &(&1.type == :workflow_step_inspection_started))
    assert state["steps"]["plan"]["status"] == "running"
    {state, token, agents}
  end

  defp result(state, token, status, seconds \\ 301) do
    WorkflowLedger.inspection_result(state, "plan", token, %{"planner" => status}, at(seconds))
  end

  test "the limit starts one async inspection; fresh work extends instead of failing" do
    state = state() |> beacon(290, 1)
    {state, token, ["planner"]} = inspect_step(state)
    assert {^state, [], []} = WorkflowLedger.reconcile(state, at(300.5))
    {state, [event], []} = result(state, token, "alive")
    assert event.type == :workflow_step_continued
    assert state["steps"]["plan"]["deadline_at"] == at(590)
    assert state["steps"]["plan"]["heartbeat_deadline_at"] == at(590)
    assert state["steps"]["plan"]["attempt_count"] == 1
    assert state["steps"]["plan"]["inspection"] == nil
  end

  test "process liveness, periodic heartbeats and duplicate progress do not renew work" do
    state = Enum.reduce(1..10, state(), fn n, acc -> beacon(acc, n * 29, 0) end)
    {state, token, _} = inspect_step(state, 330)
    {state, _, actions} = result(state, token, "alive", 331)
    assert state["steps"]["plan"]["status"] == "failed"
    assert Enum.any?(actions, &match?({:terminate_agent, "planner", _}, &1))
  end

  test "a dead worker fails even with recent progress" do
    {state, token, _} = state() |> beacon(299, 8) |> inspect_step()
    {state, _, _} = result(state, token, "dead")
    assert state["steps"]["plan"]["terminal_reason"] =~ "no longer running"
  end

  test "a bounded model/tool/human wait survives the inspection without unlimited renewal" do
    wait = %{"wait_id" => "model-request", "wait_timeout_ms" => 900_000}
    {state, token, _} = state() |> beacon(10, 1, wait) |> inspect_step()
    {state, _, []} = result(state, token, "alive")
    assert state["steps"]["plan"]["deadline_at"] == at(1210)
    state = beacon(state, 1200, 2, wait)
    {state, token, _} = inspect_step(state, 1211)
    {state, _, _} = result(state, token, "alive", 1212)
    assert state["steps"]["plan"]["status"] == "failed"
  end

  test "old attempt progress cannot rescue the current attempt" do
    state = beacon(state(), 299, 2, %{"attempt_id" => "plan:attempt:0"})
    assert state["steps"]["plan"]["progress_deadline_at"] == nil
    {state, token, _} = inspect_step(state)
    {state, _, _} = result(state, token, "alive")
    assert state["steps"]["plan"]["status"] == "failed"
  end

  test "inspection failure gets one bounded recheck, then reports a real error" do
    {state, token, _} = inspect_step(state())
    {state, _, []} = result(state, token, "unknown")
    assert state["steps"]["plan"]["deadline_at"] == at(331)
    {state, token, _} = inspect_step(state, 331)
    {state, _, _} = result(state, token, "unknown", 332)
    assert state["steps"]["plan"]["terminal_reason"] =~ "inspection unavailable"
  end

  test "an inspector that never responds cannot leave a step running forever" do
    {state, _, _} = inspect_step(state())
    {state, _, _} = WorkflowLedger.reconcile(state, at(310))
    assert state["steps"]["plan"]["terminal_reason"] =~ "inspection timed out"
  end

  test "result fencing survives snapshots and ignores stale, paused and completed attempts" do
    {state, token, _} = state() |> beacon(299, 1) |> inspect_step()
    state = state |> Jason.encode!() |> Jason.decode!()
    assert {^state, [], []} = result(state, "foreign", "alive")

    for changed <- [
          put_in(state, ["status"], "paused"),
          put_in(state, ["steps", "plan", "status"], "completed"),
          put_in(state, ["steps", "plan", "current_attempt", "attempt_id"], "plan:attempt:2")
        ] do
      assert {^changed, [], []} = result(changed, token, "alive")
    end

    {paused, _} = WorkflowLedger.pause(state, at(301))
    assert paused["steps"]["plan"]["inspection"] == nil
    {resumed, _} = WorkflowLedger.resume(paused, at(601))
    assert {^resumed, [], []} = result(resumed, token, "dead", 602)
  end

  test "explicit physical heartbeat expiry remains independent of soft execution" do
    state = state() |> beacon(250, 1)
    state = put_in(state, ["steps", "plan", "heartbeat_uses_execution_budget"], false)
    state = put_in(state, ["steps", "plan", "heartbeat_deadline_at"], at(260))
    {state, _, _} = WorkflowLedger.reconcile(state, at(261))
    assert state["steps"]["plan"]["terminal_reason"] =~ "heartbeat deadline"
  end

  test "parent inspection follows active child ownership and progress" do
    child =
      step("child", "child-worker")
      |> Map.put("parent_step_id", "plan")
      |> Map.put("progress_deadline_at", at(570))

    state = put_in(state(), ["steps", "child"], child)
    assert WorkflowSupervision.agents(state, step()) == ["child-worker"]
    {:inspect, parent, token} = WorkflowSupervision.request(step(), at(300))
    state = put_in(state, ["steps", "plan"], parent)

    assert {:continued, parent, _} =
             WorkflowSupervision.resolve(
               state,
               parent,
               token,
               %{"child-worker" => "alive"},
               at(301)
             )

    assert parent["deadline_at"] == at(570)
  end

  test "coordinator recovery replaces pending inspection tokens" do
    {state, old_token, _} = inspect_step(state())

    manifest = %MirrorNeuron.Manifest{
      type: "batch",
      flow: %{"steps" => [%{"id" => "plan", "run" => "planner"}]}
    }

    restored =
      WorkflowLedger.new(manifest, [%{node_id: "planner", config: %{}}], %{
        "workflow_state" => state
      })

    assert restored["steps"]["plan"]["inspection"] == nil
    {restored, new_token, _} = inspect_step(restored, 320)
    refute old_token == new_token
    assert {^restored, [], []} = result(restored, old_token, "dead", 321)
  end

  test "timeout retires every physical worker before the failure/retry action" do
    state = put_in(state(), ["steps", "plan", "agent_ids"], ["planner", "worker", "sink"])
    {state, token, _} = inspect_step(state)

    {_, _, actions} =
      WorkflowLedger.inspection_result(
        state,
        "plan",
        token,
        %{"planner" => "alive", "worker" => "alive", "sink" => "alive"},
        at(301)
      )

    assert Enum.map(Enum.take(actions, 3), fn {:terminate_agent, agent, _} -> agent end) == [
             "planner",
             "worker",
             "sink"
           ]
  end

  test "progress that arrives during an inspection is considered by its result" do
    {state, token, _} = inspect_step(state())
    state = beacon(state, 300.5, 1)
    {state, _, []} = result(state, token, "alive")
    assert state["steps"]["plan"]["deadline_at"] == at(600.5)
  end
end
