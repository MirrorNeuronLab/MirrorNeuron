defmodule MirrorNeuron.Runtime.WorkflowLedger.Controllers do
  @moduledoc "Applies dynamic controller patches and checkpoints to the active attempt."

  alias MirrorNeuron.Runtime.DynamicWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger.Attempts
  alias MirrorNeuron.Runtime.WorkflowLedger.State

  def apply_dynamic_graph_patch(state, step, payload, now) do
    case DynamicWorkflow.apply_patch(state, step, payload, now) do
      {:ok, next_state, event, "checkpoint_fanout"} ->
        next_state = checkpoint_controller(next_state, step["id"], now)
        {next_state, [event], []}

      {:ok, next_state, event, _strategy} ->
        {next_state, [event], []}

      {:duplicate, next_state, event, "checkpoint_fanout"} ->
        next_state = checkpoint_controller(next_state, step["id"], now)
        {next_state, [event], []}

      {:duplicate, next_state, event, _strategy} ->
        {next_state, [event], []}

      {:error, next_state, rejection_event} ->
        reason =
          Map.get(rejection_event, :reason) ||
            Map.get(rejection_event, "reason") ||
            "workflow graph patch rejected"

        {failed_state, failure_events, actions} =
          Attempts.fail_current_attempt(next_state, step, reason, now)

        {failed_state, [rejection_event | failure_events], actions}
    end
  end

  def apply_controller_checkpoint(state, step, payload, now) do
    case DynamicWorkflow.checkpoint(state, step, payload, now) do
      {:ok, next_state, event} ->
        {checkpoint_controller(next_state, step["id"], now), [event], []}

      {:error, next_state, rejection_event} ->
        reason =
          Map.get(rejection_event, :reason) ||
            Map.get(rejection_event, "reason") ||
            "workflow controller checkpoint rejected"

        {failed_state, failure_events, actions} =
          Attempts.fail_current_attempt(next_state, step, reason, now)

        {failed_state, [rejection_event | failure_events], actions}
    end
  end

  defp checkpoint_controller(state, step_id, now) do
    case State.get_step(state, step_id) do
      step when is_map(step) ->
        checkpointed =
          step
          |> State.finish_current_attempt("checkpointed", now)
          |> Map.merge(%{
            "status" => "waiting",
            "deadline_at" => nil,
            "heartbeat_deadline_at" => nil,
            "retry_at" => nil,
            "last_event_at" => now,
            "terminal_reason" => nil,
            "terminal_error" => nil,
            "last_error" => nil,
            "last_message" => nil
          })

        State.put_step(state, checkpointed)

      _ ->
        state
    end
  end
end
