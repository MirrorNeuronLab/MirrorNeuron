defmodule MirrorNeuron.Runtime.JobCoordinator.Commands do
  @moduledoc "Synchronous workflow admission, lifecycle and placement commands."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Finalization
  alias MirrorNeuron.Runtime.JobCoordinator.Health
  alias MirrorNeuron.Runtime.JobCoordinator.Messages
  alias MirrorNeuron.Runtime.JobCoordinator.Pause
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Pressure
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.RecoveryTasks
  alias MirrorNeuron.Runtime.JobCoordinator.Reports
  alias MirrorNeuron.Runtime.JobCoordinator.Services
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.JobCoordinator.Workers
  alias MirrorNeuron.Runtime.JobCoordinator.Workflow
  alias MirrorNeuron.Runtime.LiveInput
  alias MirrorNeuron.Runtime.WorkflowLedger
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.ServiceRegistry

  def handle_call(
        {:workflow_admit_message, agent_id, message},
        _from,
        %{status: "running"} = state
      ) do
    {result, ledger, events} =
      MirrorNeuron.Runtime.WorkflowAdmission.admit(state.workflow_state, agent_id, message)

    next = %{state | workflow_state: ledger}
    Workflow.publish_workflow_events(next, events)
    {:reply, result, next}
  end

  def handle_call({:workflow_admit_message, _agent_id, _message}, _from, state),
    do: {:reply, {:defer, :workflow_owner_not_running}, state}

  def handle_call({:workflow_budget, attrs}, _from, %{status: "running"} = state) do
    persist = fn budgets ->
      RedisStore.persist_job(
        state.job_id,
        Snapshots.job_snapshot(Map.put(state, :workflow_budgets, budgets))
      )
    end

    case MirrorNeuron.Runtime.WorkflowBudget.apply_command(
           Map.get(state, :workflow_budgets, %{}),
           state.manifest.policies,
           WorkflowLedger.run_id(state.workflow_state),
           attrs,
           persist
         ) do
      {:ok, response, budgets} ->
        {:reply, {:ok, response}, Map.put(state, :workflow_budgets, budgets)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:workflow_budget, _attrs}, _from, state),
    do: {:reply, {:error, "workflow budget owner is not running"}, state}

  def handle_call(:pause, _from, %{status: "running"} = state) do
    state = state |> Policy.cancel_policy_timers() |> RecoveryTasks.cancel_recovery_tasks()
    EventBus.publish(state.job_id, %{type: :job_pausing, timestamp: Runtime.timestamp()})
    {workflow_state, workflow_events} = WorkflowLedger.pause(state.workflow_state)

    next_state =
      state
      |> Map.merge(%{status: "paused", workflow_state: workflow_state})
      |> Reports.cancel_coordinator_delivery_timer()
      |> Health.cancel_health_check_timer()

    next_state = %{next_state | pause_cleanup_status: "pending"}

    case RedisStore.persist_job(state.job_id, Snapshots.job_snapshot(next_state)) do
      {:ok, _job} ->
        Processes.broadcast_agent_control(state, :pause)

        if Topology.job_type(next_state) == "service",
          do: ServiceRegistry.deregister_job(next_state.job_id)

        Workflow.publish_workflow_events(next_state, workflow_events)
        Pause.pause_cleanup(next_state)

      {:error, reason} ->
        {:reply, {:error, reason}, Health.schedule_runtime_timers(state)}
    end
  end

  def handle_call(:pause, _from, %{status: "paused", pause_cleanup_task: %Task{}} = state),
    do: {:reply, {:ok, "pause_pending"}, state}

  def handle_call(:pause, _from, %{status: "paused", pause_cleanup_status: "complete"} = state),
    do: {:reply, {:ok, "paused"}, state}

  def handle_call(:pause, _from, %{status: "paused"} = state) do
    next = %{state | pause_cleanup_status: "pending"}

    case RedisStore.persist_job(next.job_id, Snapshots.job_snapshot(next)) do
      {:ok, _job} -> Pause.pause_cleanup(next)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, "job is not running"}, state}

  def handle_call(:resume, _from, %{status: "paused", pause_cleanup_task: %Task{}} = state),
    do: {:reply, {:error, :pause_cleanup_pending}, state}

  def handle_call(:resume, _from, %{status: "paused", pause_cleanup_status: "failed"} = state),
    do: {:reply, {:error, :retry_pause_cleanup}, state}

  def handle_call(:resume, _from, %{status: "paused"} = state) do
    case Pause.restore_paused_workflow_agents(state) do
      {:ok, resumable_state} ->
        {workflow_state, workflow_events} =
          WorkflowLedger.resume(resumable_state.workflow_state)

        running_state = %{
          resumable_state
          | status: "running",
            pause_cleanup_status: nil,
            workflow_state: workflow_state
        }

        Processes.broadcast_agent_control(running_state, :resume)

        Snapshots.persist_durable_job_snapshot(
          running_state,
          Snapshots.job_snapshot(running_state)
        )

        EventBus.publish(state.job_id, %{type: :job_resumed, timestamp: Runtime.timestamp()})
        Workflow.publish_workflow_events(running_state, workflow_events)
        {:reply, {:ok, "resumed"}, Health.schedule_runtime_timers(running_state)}

      {:error, reason, failed_state} ->
        {:reply, {:error, reason}, failed_state}
    end
  end

  def handle_call(:resume, _from, %{status: "running"} = state) do
    {:reply, {:ok, "resumed"}, state}
  end

  def handle_call(:resume, _from, state), do: {:reply, {:error, "job is not paused"}, state}

  def handle_call(:cancel, _from, state) do
    Processes.broadcast_agent_control(state, :cancel)

    next_state =
      Finalization.finalize_job(
        state,
        "cancelled",
        %{reason: "cancelled by operator"},
        :job_cancelled,
        %{}
      )

    {:stop, :normal, {:ok, "cancelled"}, next_state}
  end

  def handle_call({:send_message, agent_id, message}, _from, state) do
    envelope = Messages.build_external_message(state, agent_id, message)

    envelope =
      if LiveInput.command?(state.manifest.contract, agent_id, message),
        do: envelope,
        else:
          update_in(envelope, ["headers"], &Map.drop(&1, ["mn.command_id", "mn.live_input_id"]))

    state = Pressure.refresh_pressure(state)

    case Pressure.external_input_pressure(state, agent_id, message) do
      {:retry_later, details} ->
        EventBus.publish(state.job_id, %{
          type: :external_input_rejected,
          agent_id: agent_id,
          payload: details,
          timestamp: Runtime.timestamp()
        })

        {:reply, {:error, {:retry_later, details}}, state}

      :ok ->
        case Runtime.deliver(
               state.job_id,
               agent_id,
               envelope,
               Keyword.put(
                 Pressure.node_backpressure_opts(state, agent_id),
                 :command_admitted,
                 LiveInput.command?(state.manifest.contract, agent_id, message)
               )
             ) do
          :ok -> {:reply, {:ok, "delivered"}, state}
          {:error, {:backpressure, details}} -> {:reply, {:error, {:retry_later, details}}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:pressure, _from, state) do
    next_state = Pressure.refresh_pressure(state)
    {:reply, {:ok, Pressure.pressure_summary(next_state)}, next_state}
  end

  def handle_call({:reschedule_agents, agent_ids, scheduler_plan, reason}, _from, state)
      when state.status == "running" do
    affected_agent_ids = Topology.normalize_agent_ids(agent_ids, state)

    if affected_agent_ids == [] do
      {:reply, {:error, :no_matching_agents}, state}
    else
      next_state =
        affected_agent_ids
        |> Enum.reduce(state, fn agent_id, acc ->
          acc
          |> Policy.clear_policy_timer({:restart, agent_id})
          |> Policy.clear_policy_timer({:reschedule, agent_id})
        end)
        |> Topology.put_scheduler_plan(scheduler_plan)

      EventBus.publish(state.job_id, %{
        type: :job_agent_reschedule_started,
        reason: reason,
        affected_agents: affected_agent_ids,
        timestamp: Runtime.timestamp()
      })

      Enum.each(affected_agent_ids, fn agent_id ->
        EventBus.publish(state.job_id, %{
          type: :agent_reschedule_started,
          agent_id: agent_id,
          reason: reason,
          target_node: Scheduler.target_node(scheduler_plan, agent_id),
          timestamp: Runtime.timestamp()
        })
      end)

      Processes.terminate_agent_workers(next_state, affected_agent_ids)

      with :ok <- Processes.wait_for_agents_stopped(next_state, 5_000, affected_agent_ids),
           {:ok, recovered_state} <- Workers.recover_agents(next_state, affected_agent_ids) do
        recovered_state =
          Enum.reduce(affected_agent_ids, recovered_state, fn agent_id, acc ->
            Policy.mark_policy_idle(acc, agent_id)
          end)

        Snapshots.persist_job(recovered_state)

        Enum.each(affected_agent_ids, fn agent_id ->
          EventBus.publish(state.job_id, %{
            type: :agent_rescheduled,
            agent_id: agent_id,
            reason: reason,
            target_node: Scheduler.target_node(scheduler_plan, agent_id),
            timestamp: Runtime.timestamp()
          })
        end)

        {:reply,
         {:ok,
          %{
            affected_agents: affected_agent_ids,
            scheduler: scheduler_plan
          }}, recovered_state}
      else
        {:error, failed_reason, failed_state} ->
          {:reply, {:error, failed_reason}, failed_state}

        {:error, failed_reason} ->
          {:reply, {:error, failed_reason}, next_state}
      end
    end
  end

  def handle_call({:reschedule_agents, _agent_ids, _scheduler_plan, _reason}, _from, state) do
    {:reply, {:error, "job is #{state.status}"}, state}
  end

  def handle_call(
        {:deploy_agents, agent_ids, target_manifest, scheduler_plan, deployment_context},
        _from,
        state
      )
      when state.status == "running" do
    affected_agent_ids = Topology.normalize_agent_ids(agent_ids, state)

    cond do
      affected_agent_ids == [] ->
        {:reply, {:error, :no_matching_agents}, state}

      not Topology.compatible_runtime_topology?(state, target_manifest, scheduler_plan) ->
        {:reply, {:error, "deployment target topology is not compatible with this job"}, state}

      true ->
        next_state =
          state
          |> Policy.cancel_policy_timers_for(affected_agent_ids)
          |> Topology.put_deployment_target(target_manifest, scheduler_plan, deployment_context)

        EventBus.publish(state.job_id, %{
          type: :deployment_agent_update_started,
          deployment_id: Map.get(deployment_context, "deployment_id"),
          deployment_key: Map.get(deployment_context, "deployment_key"),
          deployment_version: Map.get(deployment_context, "deployment_version"),
          deployment_role: Map.get(deployment_context, "deployment_role"),
          affected_agents: affected_agent_ids,
          timestamp: Runtime.timestamp()
        })

        Processes.terminate_agent_workers(next_state, affected_agent_ids)

        with :ok <- Processes.wait_for_agents_stopped(next_state, 5_000, affected_agent_ids),
             {:ok, deployed_state} <- Workers.deploy_agents_now(next_state, affected_agent_ids),
             :ok <- Services.register_job_services(deployed_state) do
          Snapshots.persist_job(deployed_state)

          EventBus.publish(state.job_id, %{
            type: :deployment_agent_update_completed,
            deployment_id: Map.get(deployment_context, "deployment_id"),
            deployment_key: Map.get(deployment_context, "deployment_key"),
            deployment_version: Map.get(deployment_context, "deployment_version"),
            deployment_role: Map.get(deployment_context, "deployment_role"),
            affected_agents: affected_agent_ids,
            timestamp: Runtime.timestamp()
          })

          {:reply,
           {:ok,
            %{
              affected_agents: affected_agent_ids,
              deployment: deployment_context,
              scheduler: scheduler_plan
            }}, deployed_state}
        else
          {:error, failed_reason, failed_state} ->
            {:reply, {:error, failed_reason}, failed_state}

          {:error, failed_reason} ->
            {:reply, {:error, failed_reason}, next_state}
        end
    end
  end

  def handle_call(
        {:deploy_agents, _agent_ids, _target_manifest, _scheduler_plan, _context},
        _from,
        state
      ) do
    {:reply, {:error, "job is #{state.status}"}, state}
  end
end
