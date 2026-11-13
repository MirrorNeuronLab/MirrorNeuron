defmodule MirrorNeuron.Runtime.JobCoordinator.Workflow do
  @moduledoc "Applies workflow ledger actions and enforces the owning completion boundary."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Finalization
  alias MirrorNeuron.Runtime.JobCoordinator.Messages
  alias MirrorNeuron.Runtime.JobCoordinator.Pressure
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Workers
  alias MirrorNeuron.Runtime.WorkflowLedger

  def public_agent_event_payload(event_type, payload)
      when event_type in [:workflow_graph_patch, "workflow_graph_patch"] and is_map(payload) do
    Map.take(payload, ["patch_id", "base_revision", "region_id"])
  end

  def public_agent_event_payload(event_type, payload)
      when event_type in [
             :workflow_step_attempt_completed,
             "workflow_step_attempt_completed",
             :workflow_step_completed,
             "workflow_step_completed"
           ] and is_map(payload) do
    # Worker results can contain confidential child plans. Durable artifacts/ledger own their contents.
    if contains_child_plan?(payload),
      do: Map.take(payload, ["step_id", "workflow_step_id", "attempt_id", "status"]),
      else: payload
  end

  def public_agent_event_payload(_event_type, payload), do: payload

  defp contains_child_plan?(value) when is_map(value),
    do:
      Map.has_key?(value, "child_plan") or Map.has_key?(value, :child_plan) or
        Enum.any?(Map.values(value), &contains_child_plan?/1)

  defp contains_child_plan?(value) when is_list(value),
    do: Enum.any?(value, &contains_child_plan?/1)

  defp contains_child_plan?(_), do: false

  def handle_workflow_agent_failed(state, agent_id, reason) do
    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.on_agent_failed(state.workflow_state, agent_id, reason)

    next_state = %{state | workflow_state: workflow_state}
    publish_workflow_events(next_state, workflow_events)

    case apply_workflow_actions(next_state, workflow_actions) do
      {:ok, recovered_state} ->
        continue_or_complete_workflow(recovered_state)

      {:fail_job, step_id, failed_reason, failed_state} ->
        failed_state =
          Finalization.finalize_job(
            failed_state,
            "failed",
            %{step_id: step_id, agent_id: agent_id, error: failed_reason},
            :job_failed,
            %{step_id: step_id, agent_id: agent_id, reason: failed_reason}
          )

        {:stop, {:shutdown, failed_reason}, failed_state}
    end
  end

  def handle_workflow_agent_completed_run(state, agent_id, result) do
    reason = "workflow step agent cannot complete the whole run"

    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.on_agent_failed(state.workflow_state, agent_id, reason)

    next_state = %{state | workflow_state: workflow_state}

    EventBus.publish(state.job_id, %{
      type: :workflow_run_completion_rejected,
      agent_id: agent_id,
      payload: %{"reason" => reason, "result" => result},
      timestamp: Runtime.timestamp()
    })

    publish_workflow_events(next_state, workflow_events)

    case apply_workflow_actions(next_state, workflow_actions) do
      {:ok, recovered_state} ->
        Snapshots.persist_job(recovered_state)
        {:noreply, recovered_state}

      {:fail_job, step_id, failed_reason, failed_state} ->
        failed_state =
          Finalization.finalize_job(
            failed_state,
            "failed",
            %{step_id: step_id, agent_id: agent_id, error: failed_reason},
            :job_failed,
            %{step_id: step_id, agent_id: agent_id, reason: failed_reason}
          )

        {:stop, {:shutdown, failed_reason}, failed_state}
    end
  end

  def handle_workflow_sink_completed_run(state, agent_id, result) do
    cond do
      not terminal_sink?(state, agent_id) ->
        EventBus.publish(state.job_id, %{
          type: :workflow_completion_ignored,
          agent_id: agent_id,
          payload: %{
            reason: "agent is not a declared terminal sink",
            result: result
          },
          timestamp: Runtime.timestamp()
        })

        Snapshots.persist_job(state)
        {:noreply, state}

      WorkflowLedger.completed?(state.workflow_state) ->
        next_state =
          Finalization.finalize_job(
            state,
            "completed",
            %{agent_id: agent_id, output: result, workflow_state: state.workflow_state},
            :job_completed,
            %{agent_id: agent_id, result: result, workflow: true}
          )

        {:stop, :normal, next_state}

      true ->
        timestamp = Runtime.timestamp()

        EventBus.publish(state.job_id, %{
          type: :workflow_completion_deferred,
          agent_id: agent_id,
          payload: %{
            reason: "workflow steps are not terminal",
            result: result
          },
          timestamp: timestamp
        })

        next_state = %{
          state
          | pending_workflow_completion: %{
              "agent_id" => agent_id,
              "result" => result,
              "received_at" => timestamp
            }
        }

        Snapshots.persist_job(next_state)
        {:noreply, next_state}
    end
  end

  def continue_or_complete_workflow(state) do
    case pending_workflow_completion(state) do
      nil ->
        Snapshots.persist_job(state)
        {:noreply, state}

      %{"agent_id" => agent_id, "result" => result}
      when is_binary(agent_id) ->
        if WorkflowLedger.completed?(state.workflow_state) and terminal_sink?(state, agent_id) do
          EventBus.publish(state.job_id, %{
            type: :workflow_completion_resumed,
            agent_id: agent_id,
            payload: %{"reason" => "workflow steps are terminal"},
            timestamp: Runtime.timestamp()
          })

          next_state =
            state
            |> Map.put(:pending_workflow_completion, nil)
            |> Finalization.finalize_job(
              "completed",
              %{agent_id: agent_id, output: result, workflow_state: state.workflow_state},
              :job_completed,
              %{agent_id: agent_id, result: result, workflow: true, deferred: true}
            )

          {:stop, :normal, next_state}
        else
          Snapshots.persist_job(state)
          {:noreply, state}
        end

      _other ->
        next_state = %{state | pending_workflow_completion: nil}
        Snapshots.persist_job(next_state)
        {:noreply, next_state}
    end
  end

  defp pending_workflow_completion(%{pending_workflow_completion: pending})
       when is_map(pending) do
    pending
  end

  defp pending_workflow_completion(_state), do: nil

  def reconcile_workflow(state) do
    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.reconcile(state.workflow_state)

    next_state = %{state | workflow_state: workflow_state}
    publish_workflow_events(next_state, workflow_events)

    case apply_workflow_actions(next_state, workflow_actions) do
      {:ok, applied_state} ->
        Snapshots.persist_job(applied_state)
        {:ok, applied_state}

      {:fail_job, step_id, reason, failed_state} ->
        {:fail_job, step_id, reason, failed_state}
    end
  end

  def apply_workflow_actions(state, actions) do
    Enum.reduce_while(actions, {:ok, state}, fn
      {:inspect_step, step_id, token, agents}, {:ok, acc_state} ->
        MirrorNeuron.Runtime.StepInspector.start(self(), acc_state.job_id, step_id, token, agents)
        {:cont, {:ok, acc_state}}

      {:terminate_agent, nil, _reason}, {:ok, acc_state} ->
        {:cont, {:ok, acc_state}}

      {:terminate_agent, agent_id, _reason}, {:ok, acc_state} ->
        Processes.terminate_agent_workers(acc_state, [agent_id])
        {:cont, {:ok, acc_state}}

      {:redeliver, step_id, agent_id, message}, {:ok, acc_state} ->
        case ensure_workflow_agent_ready(acc_state, agent_id) do
          {:ok, ready_state} ->
            case Runtime.deliver(
                   ready_state.job_id,
                   agent_id,
                   Messages.put_attempt_epoch(message, ready_state),
                   Pressure.node_backpressure_opts(ready_state, agent_id)
                 ) do
              :ok ->
                {:cont, {:ok, ready_state}}

              {:error, reason} ->
                {workflow_state, events} =
                  WorkflowLedger.mark_delivery_failed(
                    ready_state.workflow_state,
                    message,
                    step_id,
                    reason
                  )

                failed_state = %{ready_state | workflow_state: workflow_state}
                publish_workflow_events(failed_state, events)

                failure_reason =
                  "workflow message delivery failed: #{inspect(reason)}"

                {:halt, {:fail_job, step_id, failure_reason, failed_state}}
            end

          {:error, reason, failed_state} ->
            {:halt, {:fail_job, step_id, reason, failed_state}}
        end

      {:fail_job, step_id, reason}, {:ok, acc_state} ->
        {:halt, {:fail_job, step_id, reason, acc_state}}
    end)
  end

  defp ensure_workflow_agent_ready(state, agent_id) do
    cond do
      is_nil(agent_id) ->
        {:error, "workflow retry has no target agent", state}

      Processes.agent_ready?(state, agent_id) ->
        {:ok, state}

      true ->
        Workers.recover_agent(state, agent_id)
    end
  end

  def workflow_agent_active?(state, agent_id) do
    workflow_agent?(state, agent_id) and
      agent_id in WorkflowLedger.active_agent_ids(state.workflow_state)
  end

  def workflow_agent_inactive?(state, agent_id) do
    workflow_controls_runtime?(state) and workflow_agent?(state, agent_id) and
      not workflow_agent_active?(state, agent_id)
  end

  def workflow_agent?(state, agent_id) do
    WorkflowLedger.enabled?(state.workflow_state) and
      is_binary(WorkflowLedger.step_for_agent(state.workflow_state, agent_id))
  end

  def workflow_controls_runtime?(state) do
    workflow_agent_ids =
      state.workflow_state
      |> WorkflowLedger.agent_to_step()
      |> Map.keys()
      |> MapSet.new()

    runtime_agent_ids = MapSet.new(state.agent_ids)

    WorkflowLedger.enabled?(state.workflow_state) and
      not MapSet.disjoint?(workflow_agent_ids, runtime_agent_ids)
  end

  defp terminal_sink?(state, agent_id) do
    case Map.get(state.nodes_by_id, agent_id) do
      %{config: config} when is_map(config) ->
        Map.get(config, "terminal_sink") == true and Map.get(config, "complete_run") == true

      _ ->
        false
    end
  end

  def publish_workflow_events(_state, []), do: :ok

  def publish_workflow_events(state, events) when is_list(events) do
    Enum.each(events, &MirrorNeuron.Runtime.Signals.workflow(state.job_id, &1))

    if Enum.any?(events, fn event ->
         to_string(event[:type] || event["type"]) in ~w(workflow_step_completed workflow_step_partial workflow_step_attempt_started workflow_message_queued workflow_step_triggered workflow_child_started workflow_child_plan_committed workflow_child_round_completed workflow_graph_patch_applied workflow_controller_checkpointed)
       end),
       do: Snapshots.persist_retry_checkpoint(state)

    Enum.each(events, fn
      %{type: _type} = event ->
        EventBus.publish(state.job_id, event)

      %{"type" => _type} = event ->
        EventBus.publish(state.job_id, event)

      _event ->
        :ok
    end)
  end

  def publish_workflow_events(_state, _events), do: :ok
end
