defmodule MirrorNeuron.Runtime.JobCoordinator.PolicyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.JobCoordinator
  alias MirrorNeuron.Runtime.JobCoordinator.Policy

  test "replacing a policy timer drains only the old action and rejects a late copy" do
    key = {:restart, "worker"}
    state = %{pending_policy_timers: %{}}
    first = Policy.schedule_policy_timer(state, key, {:policy_restart, "worker", "old"}, 60_000)
    old_timer = first.pending_policy_timers[key]
    old_message = old_timer.message
    send(self(), old_timer.message)
    send(self(), :unrelated)

    next = Policy.schedule_policy_timer(first, key, {:policy_restart, "worker", "new"}, 60_000)
    new_timer = next.pending_policy_timers[key]
    on_exit(fn -> Process.cancel_timer(new_timer.ref) end)

    assert new_timer.token != old_timer.token
    assert Process.read_timer(old_timer.ref) == false
    refute_received ^old_message
    assert_received :unrelated
    assert {:noreply, ^next} = JobCoordinator.handle_info(old_timer.message, next)
  end

  test "cancelling one worker leaves other workers' restart timers active" do
    state =
      %{pending_policy_timers: %{}}
      |> Policy.schedule_policy_timer({:restart, "a"}, :restart_a, 60_000)
      |> Policy.schedule_policy_timer({:reschedule, "a"}, :reschedule_a, 60_000)
      |> Policy.schedule_policy_timer({:restart, "b"}, :restart_b, 60_000)

    other = state.pending_policy_timers[{:restart, "b"}]
    on_exit(fn -> Process.cancel_timer(other.ref) end)
    next = Policy.cancel_policy_timers_for(state, ["a"])

    assert next.pending_policy_timers == %{{:restart, "b"} => other}
    assert is_integer(Process.read_timer(other.ref))

    for key <- [{:restart, "a"}, {:reschedule, "a"}] do
      assert Process.read_timer(state.pending_policy_timers[key].ref) == false
    end
  end

  test "a current timer cannot restart a run paused after the timer was scheduled" do
    key = {:restart, "worker"}

    state =
      Policy.schedule_policy_timer(
        %{status: "paused", pending_policy_timers: %{}},
        key,
        {:policy_restart, "worker", "lost"},
        60_000
      )

    timer = state.pending_policy_timers[key]
    Process.cancel_timer(timer.ref)
    assert {:noreply, next} = JobCoordinator.handle_info(timer.message, state)
    assert next.status == "paused"
    assert next.pending_policy_timers == %{}
    assert {:noreply, ^next} = JobCoordinator.handle_info(timer.message, next)
  end

  test "marking one worker idle retains attempt history and unrelated workers" do
    state = %{
      pending_policy_timers: %{},
      policy_state: %{
        "agents" => %{
          "a" => %{"restart_history" => [10, 20], "next_action" => "restart"},
          "b" => %{"next_action" => "reschedule"}
        }
      }
    }

    next = Policy.mark_policy_idle(state, "a")
    assert next.policy_state["agents"]["a"]["restart_history"] == [10, 20]
    assert next.policy_state["agents"]["a"]["next_action"] == nil
    assert next.policy_state["agents"]["b"] == state.policy_state["agents"]["b"]
  end
end
