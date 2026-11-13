defmodule MirrorNeuron.Runtime.WorkflowLedger.Resolution do
  @moduledoc "Completes, blocks, partially resolves and skips logical steps."

  alias MirrorNeuron.Runtime.ChildWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger.Dependencies
  alias MirrorNeuron.Runtime.WorkflowLedger.Events
  alias MirrorNeuron.Runtime.WorkflowLedger.Fencing
  alias MirrorNeuron.Runtime.WorkflowLedger.Messages
  alias MirrorNeuron.Runtime.WorkflowLedger.Snapshots
  alias MirrorNeuron.Runtime.WorkflowLedger.State

  def skip_step(state, step, reason, now, opts \\ []) do
    if State.step_terminal?(step) do
      {state, [], []}
    else
      active? = Map.get(step, "status") in ["queued", "running", "retry_wait"]
      {next_state, events} = resolve_step(state, step, "skipped", %{"reason" => reason}, now)

      actions =
        if active? and Keyword.get(opts, :terminate?, false) do
          [{:terminate_agent, State.primary_agent_id(step), reason}]
        else
          []
        end

      {next_state, events, actions}
    end
  end

  def complete_step_if_ready(state, step, payload, now) do
    cond do
      Fencing.stale_attempt_output?(step, payload) ->
        Fencing.ignore_stale_step_output(state, step, payload, now)

      Dependencies.dependencies_satisfied?(state, step) and ChildWorkflow.parent?(state, step) ->
        ChildWorkflow.start(state, step, payload, now)

      Dependencies.dependencies_satisfied?(state, step) ->
        {next, events} = complete_step(state, step, payload, now)
        {next, child_events, resolution} = ChildWorkflow.completed(next, step, payload, now)

        case resolution do
          {:completed, parent, output} ->
            {next, boundary_events} =
              complete_step(next, State.get_step(next, parent), output, now)

            {next, events ++ child_events ++ boundary_events}

          {:failed, parent, reason} ->
            failed =
              Map.merge(State.get_step(next, parent), %{
                "status" => "failed",
                "terminal_reason" => reason
              })

            {State.put_step(next, failed),
             events ++
               child_events ++
               [Events.workflow_event(:workflow_step_failed, failed, %{"reason" => reason})]}

          nil ->
            {next, events ++ child_events}
        end

      true ->
        block_step_for_dependencies(state, step, Snapshots.step_last_message(step), now)
    end
  end

  defp complete_step(state, step, payload, now) do
    step =
      State.finish_current_attempt(step, "completed", now)
      |> Map.merge(%{
        "status" => "completed",
        "ended_at" => now,
        "last_event_at" => now,
        "deadline_at" => nil,
        "heartbeat_deadline_at" => nil,
        "retry_at" => nil,
        "output" => payload,
        "terminal_outcome" => "success"
      })

    state = State.put_step(state, step) |> State.put_updated_at(now)
    {state, [Events.workflow_event(:workflow_step_completed, step, %{"status" => "completed"})]}
  end

  def resolve_step(state, step, status, payload, now, opts \\ []) do
    step =
      State.finish_current_attempt(step, status, now)
      |> Map.merge(%{
        "status" => status,
        "ended_at" => now,
        "last_event_at" => now,
        "deadline_at" => nil,
        "heartbeat_deadline_at" => nil,
        "retry_at" => nil,
        "output" => payload,
        "terminal_outcome" => Keyword.get(opts, :outcome, status)
      })

    state = State.put_step(state, step) |> State.put_updated_at(now)
    event_type = if status == "skipped", do: :workflow_step_skipped, else: :workflow_step_partial
    {state, [Events.workflow_event(event_type, step, %{"status" => status})]}
  end

  def block_step_for_dependencies(state, step, message, now) do
    reason = "waiting for workflow dependencies"

    step =
      step
      |> Map.merge(%{
        "status" => "blocked",
        "last_event_at" => now,
        "terminal_reason" => reason
      })
      |> Messages.maybe_put_last_message(message)

    state =
      state
      |> State.put_step(step)
      |> Messages.maybe_put_blocked_message_status(message, step["id"], now, reason)
      |> State.put_updated_at(now)

    event =
      Events.workflow_event(:workflow_step_blocked, step, %{
        "reason" => reason,
        "blocked_on" => Dependencies.blocked_dependencies(state, step)
      })

    {state, [event]}
  end
end
