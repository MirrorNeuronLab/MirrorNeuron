defmodule MirrorNeuron.Runtime.AgentWorkerTimerTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.AgentWorker

  test "a matching delivery poll clears its timer while the agent is paused" do
    token = make_ref()
    timer_ref = make_ref()

    state = %{
      paused?: true,
      delivery_timer_ref: timer_ref,
      delivery_token: token
    }

    assert {:noreply, next_state} = AgentWorker.handle_info({:delivery_poll, token}, state)
    assert next_state.delivery_timer_ref == nil
    assert next_state.delivery_token == nil
  end

  test "a stale delivery poll cannot replace the current timer" do
    token = make_ref()

    state = %{
      paused?: false,
      delivery_timer_ref: make_ref(),
      delivery_token: token
    }

    assert {:noreply, ^state} =
             AgentWorker.handle_info({:delivery_poll, make_ref()}, state)
  end
end
