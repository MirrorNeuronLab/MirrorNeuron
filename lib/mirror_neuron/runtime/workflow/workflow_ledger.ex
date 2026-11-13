defmodule MirrorNeuron.Runtime.WorkflowLedger do
  @moduledoc "Workflow execution API and event dispatch. State transitions live in focused ledger modules."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ChildWorkflow
  alias MirrorNeuron.Runtime.DynamicWorkflow
  alias MirrorNeuron.Runtime.ServiceEventWorkflow
  alias MirrorNeuron.Runtime.WorkflowActivity
  alias MirrorNeuron.Runtime.WorkflowLedger.Attempts
  alias MirrorNeuron.Runtime.WorkflowLedger.Branches
  alias MirrorNeuron.Runtime.WorkflowLedger.Controllers
  alias MirrorNeuron.Runtime.WorkflowLedger.Definitions
  alias MirrorNeuron.Runtime.WorkflowLedger.Dependencies
  alias MirrorNeuron.Runtime.WorkflowLedger.Events
  alias MirrorNeuron.Runtime.WorkflowLedger.Fencing
  alias MirrorNeuron.Runtime.WorkflowLedger.Messages
  alias MirrorNeuron.Runtime.WorkflowLedger.Reconciliation
  alias MirrorNeuron.Runtime.WorkflowLedger.Resolution
  alias MirrorNeuron.Runtime.WorkflowLedger.Scatter
  alias MirrorNeuron.Runtime.WorkflowLedger.Snapshots
  alias MirrorNeuron.Runtime.WorkflowLedger.State
  alias MirrorNeuron.Runtime.WorkflowLedger.Values
  alias MirrorNeuron.Runtime.WorkflowPreparation

  @schema_version 3

  defdelegate disabled_state(), to: State
  defdelegate enabled?(state), to: State
  defdelegate run_id(state), to: State
  defdelegate agent_to_step(state), to: State
  defdelegate step_for_agent(state, agent_id), to: State
  defdelegate active_step_for_agent(state, agent_id), to: State
  defdelegate completed?(state), to: State
  defdelegate active_agent_ids(state), to: State
  defdelegate compact_snapshot(state), to: Snapshots
  defdelegate persistable_snapshot(state, manifest), to: Snapshots
  defdelegate decorate_message(state, agent_id, message, extra_headers \\ %{}), to: Messages
  defdelegate reconcile(state, now \\ Runtime.timestamp()), to: Reconciliation

  defdelegate inspection_result(state, step_id, token, observations, now \\ Runtime.timestamp()),
    to: Reconciliation

  @doc false
  defdelegate delivery_fence(step, agent_id, message), to: Fencing

  def new(manifest, runtime_nodes, existing_job \\ nil, job_id \\ nil) do
    definitions = Definitions.step_definitions(manifest, runtime_nodes)
    templates = Definitions.template_definitions(manifest, runtime_nodes)

    cond do
      definitions == [] ->
        State.disabled_state()

      ServiceEventWorkflow.event_only?(manifest, runtime_nodes, definitions) ->
        # Callback phases are a presentation of a live event graph, not finite
        # DAG steps. Preserve the physical output identity for every lane.
        Map.put(State.disabled_state(), "run_id", State.existing_run_id(existing_job))

      true ->
        base = %{
          "schema_version" => @schema_version,
          "enabled" => true,
          "job_id" => job_id || State.existing_job_id(existing_job),
          "run_id" => State.existing_run_id(existing_job),
          "created_at" => Runtime.timestamp(),
          "updated_at" => Runtime.timestamp(),
          "status" => "pending",
          "step_order" => Enum.map(definitions, & &1["id"]),
          "agent_to_step" => Definitions.build_agent_to_step(definitions ++ templates),
          "edges" => Definitions.graph_edges(manifest),
          "steps" => Map.new(definitions, &{&1["id"], Definitions.initial_step(&1)}),
          "messages" => %{}
        }

        flow = if is_map(manifest.flow), do: manifest.flow, else: %{}

        base
        |> DynamicWorkflow.initialize(
          flow,
          Map.new(templates, &{&1["id"], Definitions.initial_step(&1)})
        )
        |> ChildWorkflow.initialize(
          flow,
          Map.new(templates, &{&1["id"], Definitions.initial_step(&1)})
        )
        |> State.merge_existing(existing_job)
    end
  end

  def job_running(state, now \\ Runtime.timestamp()) do
    if State.enabled?(state) do
      {State.put_state_status(state, "running", now), []}
    else
      {state, []}
    end
  end

  def pause(state, now \\ Runtime.timestamp()) do
    if State.enabled?(state) do
      events =
        state
        |> State.running_steps()
        |> Enum.map(fn step ->
          Events.workflow_event(:workflow_step_blocked, step, %{
            "reason" => "job paused",
            "blocked_at" => now
          })
        end)

      {state
       |> MirrorNeuron.Runtime.WorkflowPause.pause(now)
       |> State.put_state_status("paused", now), events}
    else
      {state, []}
    end
  end

  def resume(state, now \\ Runtime.timestamp()) do
    if State.enabled?(state) do
      {state
       |> MirrorNeuron.Runtime.WorkflowPause.resume(now)
       |> State.put_state_status("running", now), []}
    else
      {state, []}
    end
  end

  def finish(state, status, now \\ Runtime.timestamp()) do
    if State.enabled?(state),
      do: State.put_state_status(state, to_string(status), now),
      else: state
  end

  def on_message_received(state, agent_id, message, now \\ Runtime.timestamp()) do
    with true <- State.enabled?(state),
         step_id when is_binary(step_id) <- Messages.step_id_for_message(state, agent_id, message),
         step when is_map(step) <- State.get_step(state, step_id) do
      fence = Fencing.delivery_fence(step, agent_id, message)

      cond do
        State.step_terminal?(step) ->
          Fencing.ignore_duplicate_step_message(
            state,
            step,
            message,
            now,
            "workflow step already terminal"
          )

        fence == :stale ->
          Fencing.ignore_duplicate_step_message(
            state,
            step,
            message,
            now,
            "delivery outside the current attempt"
          )

        fence == :sealed ->
          {Messages.put_message_status(state, message, step_id, "running", now), []}

        not Dependencies.dependencies_satisfied?(state, step) ->
          Resolution.block_step_for_dependencies(state, step, message, now)

        Fencing.step_running_with_different_message?(step, agent_id, message) ->
          Fencing.ignore_duplicate_step_message(
            state,
            step,
            message,
            now,
            "workflow step already running"
          )

        not Fencing.should_start_attempt?(step, message) ->
          {Messages.put_message_status(state, message, step_id, "running", now), []}

        true ->
          Attempts.start_attempt(state, step, agent_id, message, now)
      end
    else
      _ -> {state, []}
    end
  end

  def on_message_acked(state, agent_id, message, now \\ Runtime.timestamp()) do
    with true <- State.enabled?(state),
         step_id when is_binary(step_id) <- Messages.step_id_for_message(state, agent_id, message) do
      {Messages.put_message_status(state, message, step_id, "acked", now), []}
    else
      _ -> {state, []}
    end
  end

  def on_agent_event(state, agent_id, event_type, payload, now \\ Runtime.timestamp()) do
    with true <- State.enabled?(state),
         step_id when is_binary(step_id) <-
           Messages.step_id_from_agent_event(state, agent_id, event_type, payload),
         step when is_map(step) <- State.get_step(state, step_id) do
      normalized_event_type = Values.normalize_event_type(event_type)

      cond do
        ChildWorkflow.child?(step) and Map.get(state, "status") not in ["pending", "running"] ->
          {state, [], []}

        normalized_event_type == "workflow_step_started" and
            (step["status"] == "retry_wait" or
               (step["status"] == "queued" and (step["attempt_count"] || 0) > 0) or
               Fencing.stale_attempt_output?(step, payload)) ->
          Fencing.ignore_stale_step_output(state, step, payload, now) |> Values.without_actions()

        normalized_event_type == "agent_beacon" and Fencing.stale_attempt_output?(step, payload) ->
          {state, [], []}

        State.step_terminal?(step) ->
          Fencing.ignore_terminal_step_event(state, step, normalized_event_type, payload, now)

        true ->
          {next_state, events, actions} =
            handle_step_agent_event(state, agent_id, step, normalized_event_type, payload, now)

          {next_state, retirement_events} =
            DynamicWorkflow.retire_completed_service_patches(next_state, now)

          child_failures =
            for event <- events,
                event.type == :workflow_child_failed,
                do: {:fail_job, event.parent_step_id, event.reason}

          Reconciliation.activate_ready_steps(
            next_state,
            events ++ retirement_events,
            actions ++ child_failures,
            now
          )
      end
    else
      _ -> {state, [], []}
    end
  end

  defp handle_step_agent_event(state, agent_id, step, event_type, payload, now) do
    case event_type do
      type
      when type in [
             "runtime_preparation_started",
             "runtime_preparation_progress",
             "runtime_preparation_finished",
             "runtime_model_wait_started",
             "runtime_model_wait_finished"
           ] ->
        state = WorkflowPreparation.on_event(state, step["id"], agent_id, type, payload, now)
        {state, [], []}

      "agent_beacon" ->
        step =
          step
          |> WorkflowPreparation.advance(now)
          |> State.refresh_beacon(payload, now)
          |> WorkflowActivity.observe(payload, now)

        state = State.put_step(state, step)

        {state,
         [
           Events.workflow_event(:workflow_step_beacon, step, Events.beacon_payload(payload, now))
         ], []}

      "agent_beacon_missed" ->
        Attempts.fail_current_attempt(state, step, "agent beacon deadline exceeded", now)

      "workflow_step_started" ->
        step = State.mark_step_running(step, agent_id, now)
        state = State.put_step(state, step)

        {state,
         [Events.workflow_event(:workflow_step_attempt_started, step, %{"agent_id" => agent_id})],
         []}

      "workflow_step_completed" ->
        Resolution.complete_step_if_ready(state, step, payload, now) |> Values.without_actions()

      "workflow_step_partial" ->
        Resolution.resolve_step(state, step, "partial", payload, now) |> Values.without_actions()

      "workflow_step_skipped" ->
        {next_state, events} = Resolution.resolve_step(state, step, "skipped", payload, now)

        {next_state, skip_events, skip_actions} =
          Branches.skip_downstream_steps(next_state, step, payload, now)

        {next_state, events ++ skip_events, skip_actions}

      "workflow_step_branch" ->
        Branches.apply_branch_selection(state, step, payload, now)

      "workflow_step_scatter" ->
        Scatter.expand_scatter(state, step, payload, now)

      "workflow_graph_patch" ->
        if Fencing.stale_attempt_output?(step, payload) do
          Fencing.ignore_stale_step_output(state, step, payload, now) |> Values.without_actions()
        else
          Controllers.apply_dynamic_graph_patch(state, step, payload, now)
        end

      "workflow_controller_checkpoint" ->
        if Fencing.stale_attempt_output?(step, payload) do
          Fencing.ignore_stale_step_output(state, step, payload, now) |> Values.without_actions()
        else
          Controllers.apply_controller_checkpoint(state, step, payload, now)
        end

      "workflow_step_failed" ->
        if Fencing.stale_attempt_output?(step, payload) do
          Fencing.ignore_stale_step_output(state, step, payload, now) |> Values.without_actions()
        else
          reason = payload["error"] || payload["reason"] || "step failed"
          Attempts.fail_current_attempt(state, step, reason, now)
        end

      "workflow_step_attempt_completed" ->
        Resolution.complete_step_if_ready(state, step, payload, now) |> Values.without_actions()

      _other ->
        step = State.touch_step(step, now)
        {State.put_step(state, step), [], []}
    end
  end

  def on_agent_failed(state, agent_id, reason, now \\ Runtime.timestamp()) do
    with true <- State.enabled?(state),
         step_id when is_binary(step_id) <-
           State.active_step_for_agent(state, agent_id) || State.step_for_agent(state, agent_id),
         step when is_map(step) <- State.get_step(state, step_id) do
      if State.step_terminal?(step) do
        Fencing.ignore_terminal_step_event(
          state,
          step,
          "agent_failed",
          %{"reason" => reason},
          now
        )
      else
        reason =
          if is_map(reason), do: Events.step_error(reason, step, agent_id: agent_id), else: reason

        {next_state, events, actions} = Attempts.fail_current_attempt(state, step, reason, now)
        Reconciliation.activate_ready_steps(next_state, events, actions, now)
      end
    else
      _ -> {state, [], []}
    end
  end

  def mark_delivery_failed(state, message, step_id, reason, now \\ Runtime.timestamp()) do
    step = State.get_step(state, step_id)
    terminal_reason = "workflow message delivery failed: #{Values.stringify(reason)}"
    error = Events.step_error(terminal_reason, step)

    failed_step =
      step
      |> Map.merge(%{
        "status" => "failed",
        "current_attempt" => nil,
        "deadline_at" => nil,
        "heartbeat_deadline_at" => nil,
        "retry_at" => nil,
        "ended_at" => now,
        "last_event_at" => now,
        "terminal_reason" => terminal_reason,
        "terminal_error" => error,
        "last_error" => error
      })

    state =
      state
      |> State.put_step(failed_step)
      |> Messages.put_message_status(message, step_id, "failed", now, %{
        "reason" => Values.stringify(reason)
      })
      |> State.put_updated_at(now)

    dead_letter_event = %{
      type: :workflow_message_dead_lettered,
      step: step_id,
      message_id: Messages.safe_message_id(message),
      reason: Values.stringify(reason),
      timestamp: now
    }

    failure_event =
      Events.workflow_event(:workflow_step_failed, failed_step, %{
        "reason" => terminal_reason,
        "error" => error,
        "status" => "failed"
      })

    {state, [dead_letter_event, failure_event]}
  end
end
