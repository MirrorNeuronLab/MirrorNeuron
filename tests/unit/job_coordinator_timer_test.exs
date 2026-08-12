defmodule MirrorNeuron.Runtime.JobCoordinatorTimerTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.JobCoordinator

  test "stale policy timer messages cannot execute a replacement action" do
    key = {:restart, "worker"}
    current_token = make_ref()

    state = %{
      pending_policy_timers: %{
        key => %{token: current_token, ref: make_ref(), message: :current}
      }
    }

    stale_message =
      {:policy_timer, key, make_ref(), {:policy_restart, "worker", "stale failure"}}

    assert {:noreply, ^state} = JobCoordinator.handle_info(stale_message, state)
  end

  test "completed recovery tasks are demonitored and removed" do
    task = Task.async(fn -> :completed end)
    state = %{job_id: "task-job", recovery_tasks: %{task.ref => task}}

    assert_receive {ref, :completed}
    assert ref == task.ref

    assert {:noreply, next_state} =
             JobCoordinator.handle_info({task.ref, :completed}, state)

    assert next_state.recovery_tasks == %{}
    refute_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  test "coordinator termination cancels in-flight recovery tasks" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :recovery_task_started)
        Process.sleep(:infinity)
      end)

    assert_receive :recovery_task_started

    state = %{
      recovery_tasks: %{task.ref => task},
      pending_policy_timers: %{},
      health_check_timer_ref: nil,
      health_check_token: nil
    }

    assert :ok = JobCoordinator.terminate(:normal, state)
    refute Process.alive?(task.pid)
  end

  test "paused coordinators discard health checks instead of recovering stopped service agents" do
    token = make_ref()

    state = %{
      status: "paused",
      health_check_timer_ref: nil,
      health_check_token: token
    }

    assert {:noreply, next_state} =
             JobCoordinator.handle_info({:health_check, token}, state)

    assert next_state.health_check_timer_ref == nil
    assert next_state.health_check_token == nil
  end
end
