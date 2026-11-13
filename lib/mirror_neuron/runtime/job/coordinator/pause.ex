defmodule MirrorNeuron.Runtime.JobCoordinator.Pause do
  @moduledoc "Stops paused work and records resumable cleanup or manual-review receipts."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runner
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.RecoveryTasks
  alias MirrorNeuron.Runtime.JobCoordinator.Services
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.JobCoordinator.Workers
  alias MirrorNeuron.Runtime.WorkflowLedger

  def pause_cleanup(state) do
    result =
      if Topology.job_type(state) == "service" do
        task =
          RecoveryTasks.start_owned_recovery_task(fn ->
            stop_for_pause(state, state.agent_ids)
          end)

        case Task.yield(task, 250) do
          {:ok, result} -> result
          {:exit, reason} -> {:error, reason}
          nil -> {:pending, task}
        end
      else
        stop_for_pause(state, WorkflowLedger.active_agent_ids(state.workflow_state))
      end

    case result do
      {:pending, task} ->
        next = %{state | pause_cleanup_task: task, pause_cleanup_status: "pending"}
        {:reply, {:ok, "pause_pending"}, next}

      result ->
        {receipt, next} = finish_pause_cleanup(state, result)
        {:reply, receipt, next}
    end
  end

  defp stop_for_pause(state, agent_ids) do
    Processes.terminate_agent_workers(state, agent_ids)

    stopped = Processes.wait_for_agents_stopped(state, 5_000, agent_ids)
    cleanup = stop_paused_commands(state)
    with :ok <- stopped, do: cleanup
  end

  def finish_pause_cleanup(state, result) do
    {status, event, receipt} =
      case result do
        :ok ->
          {"complete", :job_paused, {:ok, "paused"}}

        {:error, reason} ->
          {"failed", :job_pause_cleanup_failed, {:error, {:pause_cleanup_failed, reason}}}

        reason ->
          {"failed", :job_pause_cleanup_failed, {:error, {:pause_cleanup_failed, reason}}}
      end

    next = %{state | pause_cleanup_task: nil, pause_cleanup_status: status}

    case RedisStore.persist_job(next.job_id, Snapshots.job_snapshot(next)) do
      {:ok, _job} ->
        EventBus.publish(state.job_id, %{type: event, timestamp: Runtime.timestamp()})
        {receipt, next}

      {:error, reason} ->
        {{:error, reason}, %{next | pause_cleanup_status: "failed"}}
    end
  end

  def restore_paused_workflow_agents(state) do
    agent_ids =
      cond do
        Topology.job_type(state) == "service" ->
          state.agent_ids

        WorkflowLedger.enabled?(state.workflow_state) ->
          WorkflowLedger.active_agent_ids(state.workflow_state)

        true ->
          []
      end

    # A fresh coordinator still reconciles the physical stop after recovery.
    cleanup =
      if state.pause_cleanup_status == "complete", do: :ok, else: stop_paused_commands(state)

    with :ok <- cleanup do
      restore_paused_agents(state, agent_ids)
    else
      {:error, reason} -> {:error, {:pause_cleanup_failed, reason}, state}
    end
  end

  defp stop_paused_commands(state) do
    if Topology.job_type(state) == "service" do
      with :ok <- Runner.stop_prepared(Enum.map(state.runtime_nodes, & &1.config), :pause),
           do: Runtime.cleanup_job_sandboxes(state.job_id)
    else
      case WorkflowLedger.active_agent_ids(state.workflow_state) do
        [] ->
          :ok

        agent_ids ->
          configs =
            state.nodes_by_id
            |> Map.take(agent_ids)
            |> Enum.map(fn {_id, node} -> node.config end)

          with :ok <- Runner.stop_prepared(configs, :pause) do
            MirrorNeuron.Runtime.JobCleanup.stop_agent_commands(
              state.job_id,
              %{scheduler: Topology.scheduler_plan(state)},
              agent_ids
            )
          end
      end
    end
  end

  defp restore_paused_agents(state, agent_ids) do
    case Workers.recover_agents(
           state,
           agent_ids,
           %{
             "paused" => true,
             "reclaim_deliveries" => true,
             "service_resume_token" => Base.encode16(:crypto.strong_rand_bytes(16))
           }
         ) do
      {:ok, recovered_state} ->
        case Services.register_resumed_job_services(recovered_state) do
          :ok -> {:ok, recovered_state}
          {:error, reason} -> {:error, reason, recovered_state}
        end

      error ->
        error
    end
  end

  def pause_for_policy_review(state, agent_id, reason) do
    state = Policy.cancel_policy_timers(state)
    Processes.terminate_agent_workers(state)

    next_state =
      state
      |> Policy.put_policy_agent_fields(agent_id, %{
        "last_reason" => reason,
        "next_action" => nil,
        "next_eligible_at" => nil,
        "exhausted_reason" => reason,
        "requires_review" => true
      })
      |> Map.merge(%{
        status: "paused",
        result: %{"reason" => reason, "agent_id" => agent_id}
      })

    Snapshots.persist_job_with_recovery(next_state, reason)

    EventBus.publish(state.job_id, %{
      type: :job_paused_for_manual_restart,
      agent_id: agent_id,
      reason: reason,
      timestamp: Runtime.timestamp()
    })

    next_state
  end

  def pause_for_profile_review(state, profile, agent_id, reason) do
    state = Policy.cancel_policy_timers(state)
    Processes.terminate_agent_workers(state)

    next_state = %{
      state
      | status: "paused",
        result: %{"reason" => reason, "agent_id" => agent_id}
    }

    Snapshots.persist_job_with_recovery(next_state, reason)

    EventBus.publish(state.job_id, %{
      type: :job_paused_for_manual_restart,
      agent_id: agent_id,
      execution_profile: profile,
      reason: reason,
      timestamp: Runtime.timestamp()
    })

    next_state
  end
end
