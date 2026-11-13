defmodule MirrorNeuron.Runtime.JobCoordinator.Health do
  @moduledoc "Reconciles run health with token-scoped periodic checks."

  alias MirrorNeuron.Runtime.JobCoordinator.Finalization
  alias MirrorNeuron.Runtime.JobCoordinator.Pressure
  alias MirrorNeuron.Runtime.JobCoordinator.Recovery
  alias MirrorNeuron.Runtime.JobCoordinator.Reports
  alias MirrorNeuron.Runtime.JobCoordinator.Workflow

  def run_health_check(state, reschedule?) do
    state = Pressure.refresh_pressure(state)

    case Recovery.schedule_missing_agents(state) do
      {:ok, next_state} ->
        case Workflow.reconcile_workflow(next_state) do
          {:ok, reconciled_state} ->
            case Workflow.continue_or_complete_workflow(reconciled_state) do
              {:noreply, continued_state} ->
                {:noreply, maybe_schedule_health_check(continued_state, reschedule?)}

              {:stop, _reason, _completed_state} = stop ->
                stop
            end

          {:fail_job, step_id, reason, failed_state} ->
            failed_state =
              Finalization.finalize_job(
                failed_state,
                "failed",
                %{step_id: step_id, error: reason},
                :job_failed,
                %{step_id: step_id, reason: reason}
              )

            {:stop, {:shutdown, reason}, failed_state}
        end

      {:error, reason, next_state} ->
        Recovery.restart_clean_attempt(next_state, reason)
    end
  end

  defp maybe_schedule_health_check(state, true), do: schedule_health_check(state)

  defp maybe_schedule_health_check(state, false), do: state

  defp schedule_health_check(state) do
    state = cancel_health_check_timer(state)
    token = make_ref()
    ref = Process.send_after(self(), {:health_check, token}, state.health_check_interval_ms)
    %{state | health_check_timer_ref: ref, health_check_token: token}
  end

  def cancel_health_check_timer(%{health_check_timer_ref: ref, health_check_token: token} = state)
      when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:health_check, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_health_check_timer(state)
  end

  def cancel_health_check_timer(state), do: state

  def clear_health_check_timer(state),
    do: %{state | health_check_timer_ref: nil, health_check_token: nil}

  def schedule_runtime_timers(state) do
    state
    |> schedule_health_check()
    |> Reports.schedule_coordinator_delivery_poll(0)
  end
end
