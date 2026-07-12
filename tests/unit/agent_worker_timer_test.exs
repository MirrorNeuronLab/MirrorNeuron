defmodule MirrorNeuron.Runtime.AgentWorkerTimerTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.AgentWorker

  test "manual pending drains replace queued drain work instead of duplicating it" do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:drain_pending, token}, 60_000)

    state = %{
      paused?: true,
      drain_timer_ref: timer_ref,
      drain_token: token
    }

    assert {:noreply, next_state} = AgentWorker.handle_info(:drain_pending, state)
    assert next_state.drain_timer_ref == nil
    assert next_state.drain_token == nil
    assert Process.read_timer(timer_ref) == false
  end

  test "stale pending drain messages cannot consume current work" do
    token = make_ref()

    state = %{
      paused?: false,
      drain_timer_ref: make_ref(),
      drain_token: token
    }

    assert {:noreply, ^state} =
             AgentWorker.handle_info({:drain_pending, make_ref()}, state)
  end
end
