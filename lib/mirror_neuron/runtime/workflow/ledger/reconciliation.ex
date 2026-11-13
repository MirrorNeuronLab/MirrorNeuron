defmodule MirrorNeuron.Runtime.WorkflowLedger.Reconciliation do
  @moduledoc "Reconciles deadlines, retries and dependency activation without performing delivery."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ChildWorkflow
  alias MirrorNeuron.Runtime.DynamicWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger.Attempts
  alias MirrorNeuron.Runtime.WorkflowLedger.Dependencies
  alias MirrorNeuron.Runtime.WorkflowLedger.Events
  alias MirrorNeuron.Runtime.WorkflowLedger.Messages
  alias MirrorNeuron.Runtime.WorkflowLedger.Resolution
  alias MirrorNeuron.Runtime.WorkflowLedger.Snapshots
  alias MirrorNeuron.Runtime.WorkflowLedger.State
  alias MirrorNeuron.Runtime.WorkflowLedger.Values
  alias MirrorNeuron.Runtime.WorkflowPreparation
  alias MirrorNeuron.Runtime.WorkflowSupervision

  def reconcile(state, now \\ Runtime.timestamp()) do
    if State.enabled?(state) and Map.get(state, "status") == "running" do
      state
      |> Map.get("step_order", [])
      |> Enum.reduce({state, [], []}, fn step_id, {acc_state, events, actions} ->
        step = State.get_step(acc_state, step_id)
        {next_state, next_events, next_actions} = reconcile_step(acc_state, step, now)
        {next_state, events ++ next_events, actions ++ next_actions}
      end)
    else
      {state, [], []}
    end
  end

  def inspection_result(state, step_id, token, observations, now \\ Runtime.timestamp()) do
    step = get_in(state, ["steps", step_id]) || %{}

    case WorkflowSupervision.resolve(state, step, token, observations, now) do
      :stale ->
        {state, [], []}

      {:continued, step, reason} ->
        {State.put_step(state, step),
         [
           Events.workflow_event(:workflow_step_continued, step, %{
             "reason" => reason,
             "deadline_at" => step["deadline_at"]
           })
         ], []}

      {:failed, reason} ->
        {state, events, actions} = Attempts.fail_current_attempt(state, step, reason, now)

        event =
          Events.workflow_event(:workflow_step_attempt_timed_out, step, %{"reason" => reason})

        {state, [event | events], timeout_terminations(state, step, reason) ++ actions}
    end
  end

  defp timeout_terminations(state, step, reason) do
    Enum.uniq((step["agent_ids"] || []) ++ WorkflowSupervision.agents(state, step))
    |> Enum.map(&{:terminate_agent, &1, reason})
  end

  defp reconcile_step(state, %{"status" => "running"} = step, now) do
    step = WorkflowPreparation.advance(step, now)
    state = State.put_step(state, step)

    cond do
      WorkflowPreparation.expired?(step, now) ->
        reason = "workflow step preparation deadline exceeded"
        {state, events, actions} = Attempts.fail_current_attempt(state, step, reason, now)
        {state, events, timeout_terminations(state, step, reason) ++ actions}

      not step["heartbeat_uses_execution_budget"] and
          Values.expired?(Map.get(step, "heartbeat_deadline_at"), now) ->
        {state, events, actions} =
          Attempts.fail_current_attempt(
            state,
            step,
            "workflow step heartbeat deadline exceeded",
            now
          )

        {state,
         [
           Events.workflow_event(:workflow_step_attempt_timed_out, step, %{
             "reason" => "heartbeat deadline exceeded"
           })
           | events
         ],
         timeout_terminations(state, step, "workflow step heartbeat deadline exceeded") ++ actions}

      Values.expired?(step["deadline_at"], now) or
          Values.expired?(step["progress_deadline_at"], now) ->
        case WorkflowSupervision.request(step, now) do
          :pending ->
            {state, [], []}

          {:inspect, inspected, token} ->
            event =
              Events.workflow_event(:workflow_step_inspection_started, inspected, %{
                "reason" => "soft deadline reached"
              })

            {State.put_step(state, inspected), [event],
             [{:inspect_step, step["id"], token, WorkflowSupervision.agents(state, step)}]}

          {:failed, reason} ->
            {state, events, actions} = Attempts.fail_current_attempt(state, step, reason, now)
            {state, events, timeout_terminations(state, step, reason) ++ actions}
        end

      true ->
        {state, [], []}
    end
  end

  defp reconcile_step(state, %{"status" => "retry_wait"} = step, now) do
    if Values.expired?(Map.get(step, "retry_at"), now) do
      case Attempts.retry_message(state, step, now) do
        {:ok, message, step} ->
          state = State.put_step(state, step)
          {state, [], [{:redeliver, step["id"], State.primary_agent_id(step), message}]}

        {:error, reason} ->
          state =
            State.put_step(
              state,
              Map.merge(step, %{
                "status" => "failed",
                "terminal_reason" => reason,
                "terminal_error" => Events.step_error(reason, step)
              })
            )

          {state,
           [
             Events.workflow_event(:workflow_step_failed, step, %{
               "reason" => reason,
               "error" => Events.step_error(reason, step),
               "status" => "failed"
             })
           ], [{:fail_job, step["id"], reason}]}
      end
    else
      {state, [], []}
    end
  end

  defp reconcile_step(state, %{"status" => "blocked"} = step, now) do
    cond do
      Dependencies.dependencies_satisfied?(state, step) ->
        redeliver_or_trigger(state, step, now)

      Dependencies.dependencies_impossible?(state, step) ->
        Resolution.skip_step(state, step, "trigger rule cannot be satisfied", now)

      true ->
        {state, [], []}
    end
  end

  defp reconcile_step(state, %{"status" => status} = step, now)
       when status in ["pending", "ready"] do
    cond do
      Dependencies.dependencies_impossible?(state, step) ->
        Resolution.skip_step(state, step, "trigger rule cannot be satisfied", now)

      Dependencies.dependencies_satisfied?(state, step) and
          synthetic_trigger_required?(state, step) ->
        redeliver_or_trigger(state, step, now)

      Dependencies.dependencies_satisfied?(state, step) and Snapshots.last_message_present?(step) ->
        redeliver_or_trigger(state, step, now)

      true ->
        {state, [], []}
    end
  end

  defp reconcile_step(state, _step, _now), do: {state, [], []}

  def activate_ready_steps(state, events, actions, now) do
    {next_state, ready_events, ready_actions} =
      state
      |> Map.get("step_order", [])
      |> Enum.reduce({state, [], []}, fn step_id, {acc_state, acc_events, acc_actions} ->
        step = State.get_step(acc_state, step_id)

        if is_map(step) and immediate_activation_required?(acc_state, step) do
          {updated_state, step_events, step_actions} = reconcile_step(acc_state, step, now)
          {updated_state, acc_events ++ step_events, acc_actions ++ step_actions}
        else
          {acc_state, acc_events, acc_actions}
        end
      end)

    {next_state, events ++ ready_events, actions ++ ready_actions}
  end

  defp immediate_activation_required?(state, step) do
    Map.get(step, "status") in ["pending", "ready", "blocked"] and
      (Dependencies.dependencies_impossible?(state, step) or
         (Dependencies.dependencies_satisfied?(state, step) and
            not Snapshots.last_message_present?(step) and
            synthetic_trigger_required?(state, step)))
  end

  defp redeliver_or_trigger(state, step, now) do
    {step, saved_message} =
      if step["checkpoint_retry_delivery"] == true and Snapshots.last_message_present?(step) do
        {:ok, message, next_step} = Attempts.retry_message(state, step, now)
        {Map.delete(next_step, "checkpoint_retry_delivery"), message}
      else
        # A parent sink emits before its child rounds finish. Managed targets
        # must consume the ledger's final parent outputs, not that early body.
        message =
          if ChildWorkflow.managed_target?(state, step),
            do: nil,
            else: Snapshots.step_last_message(step)

        {step, message}
      end

    case saved_message do
      message when is_map(message) ->
        step =
          step
          |> Map.merge(%{
            "status" => "queued",
            "last_event_at" => now,
            "terminal_reason" => nil,
            "terminal_error" => nil,
            "last_error" => nil
          })

        state = State.put_step(state, step) |> State.put_updated_at(now)
        {state, [], [{:redeliver, step["id"], State.primary_agent_id(step), message}]}

      _ ->
        trigger_message = synthetic_trigger_message(state, step, now)

        step =
          step
          |> Map.merge(%{
            "status" => "queued",
            "last_event_at" => now,
            "last_message" => trigger_message,
            "terminal_reason" => nil,
            "terminal_error" => nil,
            "last_error" => nil
          })

        state = State.put_step(state, step) |> State.put_updated_at(now)

        event =
          Events.workflow_event(:workflow_step_triggered, step, %{
            "trigger_rule" => step["trigger_rule"]
          })

        {state, [event],
         [{:redeliver, step["id"], State.primary_agent_id(step), trigger_message}]}
    end
  end

  defp synthetic_trigger_required?(state, step) do
    rule = get_in(step, ["trigger_rule", "rule"])
    edges = Dependencies.incoming_edges(state, step)

    cond do
      ChildWorkflow.managed_target?(state, step) ->
        true

      DynamicWorkflow.managed_target?(state, step) ->
        true

      rule == "one_failed" ->
        true

      rule == "all_done" ->
        Enum.any?(edges, &Dependencies.dependency_failed?(state, &1))

      rule == "one_done" ->
        Enum.any?(edges, fn edge ->
          Dependencies.dependency_terminal?(state, edge) and
            not Dependencies.dependency_success?(state, edge)
        end)

      true ->
        false
    end
  end

  defp synthetic_trigger_message(state, step, now) do
    parents =
      state
      |> Dependencies.incoming_edges(step)
      |> Enum.map(fn edge ->
        parent = State.get_step(state, Map.get(edge, "from")) || %{}

        %{
          "step_id" => Map.get(edge, "from"),
          "status" => Map.get(parent, "status"),
          "outcome" => Map.get(parent, "terminal_outcome"),
          "output" => Snapshots.step_output(parent),
          "edge_id" => Map.get(edge, "id")
        }
      end)

    step_metadata =
      %{
        "graph_revision" => DynamicWorkflow.graph_revision(state),
        "template_id" => Map.get(step, "template_id"),
        "region_id" => Map.get(step, "region_id"),
        "step_input" => Map.get(step, "instance_input"),
        "parent_step_id" => step["parent_step_id"],
        "child_round" => step["child_round"],
        "child_phase" => step["child_phase"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    message =
      Message.new(
        Map.get(state, "job_id") || State.run_id(state),
        "workflow_ledger",
        State.primary_agent_id(step),
        "workflow_trigger",
        %{
          "trigger_rule" => step["trigger_rule"],
          "parents" => parents,
          "_mn_step" => step_metadata,
          "step_input" => Map.get(step, "instance_input")
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
        timestamp: now,
        class: "command"
      )

    Messages.decorate_step_message(state, step, message)
  end
end
