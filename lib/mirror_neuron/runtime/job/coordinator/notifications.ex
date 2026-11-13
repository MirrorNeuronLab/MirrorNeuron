defmodule MirrorNeuron.Runtime.JobCoordinator.Notifications do
  @moduledoc "Routes owned task results, durable reports and fenced timers."

  require Logger

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Bootstrap
  alias MirrorNeuron.Runtime.JobCoordinator.Finalization
  alias MirrorNeuron.Runtime.JobCoordinator.Health
  alias MirrorNeuron.Runtime.JobCoordinator.Pause
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Pressure
  alias MirrorNeuron.Runtime.JobCoordinator.Recovery
  alias MirrorNeuron.Runtime.JobCoordinator.RecoveryTasks
  alias MirrorNeuron.Runtime.JobCoordinator.Reports
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Targets
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.JobCoordinator.Workflow
  alias MirrorNeuron.Runtime.WorkflowLedger

  def handle_cast(:coordinator_delivery_available, %{status: "running"} = state) do
    {:noreply, Reports.schedule_coordinator_delivery_poll(state, 0)}
  end

  def handle_cast(:coordinator_delivery_available, state), do: {:noreply, state}

  def handle_info(
        {:submission_storage_check, token},
        %{status: "pending", submission_storage: %{timer_token: token}} = state
      ) do
    state = Bootstrap.clear_submission_storage_check(state)
    Bootstrap.continue_bootstrap_after_storage_check(state)
  end

  def handle_info({:submission_storage_check, _token}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{submission_storage: %{check_task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    state = MirrorNeuron.Runtime.SubmissionPreparation.received(state, result)

    if state.status == "pending",
      do: Bootstrap.continue_bootstrap_after_storage_check(state),
      else: {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{submission_storage: %{check_task: %Task{ref: ref}}} = state
      ) do
    state =
      MirrorNeuron.Runtime.SubmissionPreparation.received(
        state,
        {:error, "submission_readiness_inspection_failed", %{}}
      )

    if state.status == "pending",
      do: Bootstrap.continue_bootstrap_after_storage_check(state),
      else: {:noreply, state}
  end

  def handle_info(
        {:coordinator_delivery_poll, token},
        %{coordinator_delivery_token: token, status: "running"} = state
      ) do
    state = Reports.clear_coordinator_delivery_timer(state)
    Reports.poll_coordinator_deliveries(state)
  end

  def handle_info(
        {:coordinator_delivery_poll, token},
        %{coordinator_delivery_token: token} = state
      ) do
    {:noreply, Reports.clear_coordinator_delivery_timer(state)}
  end

  def handle_info({:coordinator_delivery_poll, _stale_token}, state), do: {:noreply, state}

  def handle_info({:agent_event, agent_id, event_type, payload}, state) do
    state = MirrorNeuron.Runtime.RunLifecycle.observe(state, agent_id, event_type, payload)

    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.on_agent_event(state.workflow_state, agent_id, event_type, payload)

    state = %{state | workflow_state: workflow_state}

    EventBus.publish(state.job_id, %{
      type: event_type,
      agent_id: agent_id,
      payload: Workflow.public_agent_event_payload(event_type, payload),
      timestamp: Runtime.timestamp()
    })

    Workflow.publish_workflow_events(state, workflow_events)

    case Workflow.apply_workflow_actions(state, workflow_actions) do
      {:ok, next_state} ->
        Workflow.continue_or_complete_workflow(next_state)

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
  end

  def handle_info(
        {:workflow_step_inspected, _step_id, _token, _observations},
        %{status: status} = state
      )
      when status != "running", do: {:noreply, state}

  def handle_info({:workflow_step_inspected, step_id, token, observations}, state) do
    {ledger, events, actions} =
      WorkflowLedger.inspection_result(state.workflow_state, step_id, token, observations)

    state = %{state | workflow_state: ledger}
    Workflow.publish_workflow_events(state, events)

    case Workflow.apply_workflow_actions(state, actions) do
      {:ok, next_state} ->
        Snapshots.persist_job(next_state)
        Workflow.continue_or_complete_workflow(next_state)

      {:fail_job, failed_step, reason, failed_state} ->
        failed_state =
          Finalization.finalize_job(
            failed_state,
            "failed",
            %{step_id: failed_step, error: reason},
            :job_failed,
            %{step_id: failed_step, reason: reason}
          )

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  def handle_info({:workflow_message_received, agent_id, message}, state) do
    {workflow_state, workflow_events} =
      WorkflowLedger.on_message_received(state.workflow_state, agent_id, message)

    next_state = %{state | workflow_state: workflow_state}
    Workflow.publish_workflow_events(next_state, workflow_events)
    Workflow.continue_or_complete_workflow(next_state)
  end

  def handle_info({:workflow_message_acked, agent_id, message}, state) do
    {workflow_state, workflow_events} =
      WorkflowLedger.on_message_acked(state.workflow_state, agent_id, message)

    next_state = %{state | workflow_state: workflow_state}
    Workflow.publish_workflow_events(next_state, workflow_events)
    Workflow.continue_or_complete_workflow(next_state)
  end

  def handle_info({:agent_pressure, agent_id, pressure}, state) do
    previous = Map.get(state.pressure, agent_id)
    next_state = put_in(state.pressure[agent_id], pressure)

    if Pressure.pressure_event_changed?(previous, pressure) do
      EventBus.publish(state.job_id, %{
        type: :backpressure_state,
        agent_id: agent_id,
        payload: pressure,
        timestamp: Runtime.timestamp()
      })
    end

    {:noreply, next_state}
  end

  # Exit notifications from stopped agents cannot restart a paused service.

  def handle_info({signal, _agent, _result}, %{status: "paused"} = state)
      when signal in [:agent_failed, :agent_completed_run],
      do: {:noreply, state}

  def handle_info({:agent_completed_run, agent_id, result}, state) do
    cond do
      Workflow.workflow_agent?(state, agent_id) ->
        Workflow.handle_workflow_agent_completed_run(state, agent_id, result)

      Workflow.workflow_controls_runtime?(state) ->
        Workflow.handle_workflow_sink_completed_run(state, agent_id, result)

      true ->
        case Topology.job_type(state) do
          "service" ->
            Targets.restart_service_agent(state, agent_id, result)

          "system" ->
            Targets.restart_system_target(state, agent_id, result)

          "sysbatch" ->
            Targets.complete_sysbatch_target(state, agent_id, result)

          _batch ->
            next_state =
              Finalization.finalize_job(
                state,
                "completed",
                %{agent_id: agent_id, output: result},
                :job_completed,
                %{agent_id: agent_id, result: result}
              )

            {:stop, :normal, next_state}
        end
    end
  end

  def handle_info({:agent_delivery_exhausted, _agent_id, _message_id}, %{status: status} = state)
      when status not in ["pending", "running"],
      do: {:noreply, state}

  def handle_info({:agent_delivery_exhausted, agent_id, message_id}, state) do
    if Recovery.service_auxiliary_retry_safe?(state, agent_id, %{}) do
      error =
        ErrorEnvelope.normalize(
          %{"agent_id" => agent_id, "message_id" => message_id},
          code: "runtime.service.delivery_exhausted",
          desc: "Service work exhausted its delivery retry budget.",
          component: "agent_worker",
          agent_id: agent_id,
          retryable: false
        )

      next_state =
        Finalization.finalize_job(state, "failed", %{error: error}, :job_failed, %{
          agent_id: agent_id,
          reason: error
        })

      {:stop, :normal, next_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:agent_failed, agent_id, reason}, state) do
    if Workflow.workflow_agent_active?(state, agent_id) do
      Workflow.handle_workflow_agent_failed(state, agent_id, reason)
    else
      Recovery.handle_runtime_agent_failed(state, agent_id, reason)
    end
  end

  def handle_info({:policy_timer, key, token, message}, state) do
    case Map.get(state.pending_policy_timers, key) do
      %{token: ^token} ->
        state = Policy.drop_policy_timer(state, key)
        handle_info(message, state)

      _stale_or_cancelled ->
        {:noreply, state}
    end
  end

  def handle_info({:policy_restart, agent_id, _reason}, %{status: status} = state)
      when status != "running" do
    {:noreply, Policy.clear_policy_timer(state, {:restart, agent_id})}
  end

  def handle_info({:policy_restart, agent_id, reason}, state) do
    next_state = Policy.clear_policy_timer(state, {:restart, agent_id})

    case Recovery.restart_agents_now(next_state, [agent_id], reason) do
      {:ok, recovered_state} ->
        recovered_state = Policy.mark_policy_idle(recovered_state, agent_id)
        Snapshots.persist_job(recovered_state)
        {:noreply, recovered_state}

      {:error, failed_reason, failed_state} ->
        case Recovery.schedule_agent_restarts(failed_state, [agent_id], failed_reason) do
          {:ok, retry_state} ->
            {:noreply, retry_state}

          {:error, final_reason, final_state} ->
            failed_state =
              Finalization.finalize_job(
                final_state,
                "failed",
                %{agent_id: agent_id, error: final_reason},
                :job_failed,
                %{agent_id: agent_id, reason: final_reason}
              )

            {:stop, {:shutdown, final_reason}, failed_state}
        end
    end
  end

  def handle_info({:policy_reschedule, agent_ids, _reason}, %{status: status} = state)
      when status != "running" do
    {:noreply, Enum.reduce(agent_ids, state, &Policy.clear_policy_timer(&2, {:reschedule, &1}))}
  end

  def handle_info({:policy_reschedule, agent_ids, reason}, state) do
    affected_agent_ids = Topology.normalize_agent_ids(agent_ids, state)

    next_state =
      Enum.reduce(affected_agent_ids, state, fn agent_id, acc ->
        Policy.clear_policy_timer(acc, {:reschedule, agent_id})
      end)

    {:noreply, RecoveryTasks.start_reschedule_task(next_state, affected_agent_ids, reason)}
  end

  def handle_info({ref, result}, %{pause_cleanup_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {_receipt, next} = Pause.finish_pause_cleanup(state, result)
    {:noreply, next}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{pause_cleanup_task: %Task{ref: ref}} = state
      ) do
    {_receipt, next} = Pause.finish_pause_cleanup(state, {:error, reason})
    {:noreply, next}
  end

  def handle_info({ref, result}, %{recovery_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    RecoveryTasks.maybe_log_recovery_task_failure(state.job_id, result)
    {:noreply, RecoveryTasks.drop_recovery_task(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{recovery_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    if reason != :normal do
      Logger.warning(
        "recovery task for job #{state.job_id} exited unexpectedly: #{inspect(reason)}"
      )
    end

    {:noreply, RecoveryTasks.drop_recovery_task(state, ref)}
  end

  def handle_info({:health_check, token}, %{health_check_token: token, status: "running"} = state) do
    state |> Health.clear_health_check_timer() |> Health.run_health_check(true)
  end

  def handle_info({:health_check, token}, %{health_check_token: token} = state),
    do: {:noreply, Health.clear_health_check_timer(state)}

  def handle_info({:health_check, _stale_token}, state), do: {:noreply, state}

  def handle_info(:health_check, %{status: "running"} = state) do
    Health.run_health_check(state, false)
  end

  def handle_info(:health_check, state), do: {:noreply, Health.clear_health_check_timer(state)}
end
