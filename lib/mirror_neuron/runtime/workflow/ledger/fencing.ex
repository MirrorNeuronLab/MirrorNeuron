defmodule MirrorNeuron.Runtime.WorkflowLedger.Fencing do
  @moduledoc "Rejects obsolete attempts, duplicate deliveries and events for terminal steps."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.WorkflowLedger.Events
  alias MirrorNeuron.Runtime.WorkflowLedger.Messages
  alias MirrorNeuron.Runtime.WorkflowLedger.Snapshots
  alias MirrorNeuron.Runtime.WorkflowLedger.State

  def ignore_stale_step_output(state, step, payload, now) do
    step = State.touch_step(step, now)
    state = State.put_step(state, step) |> State.put_updated_at(now)

    event =
      Events.workflow_event(:workflow_step_stale_output_ignored, step, %{
        "reason" => "attempt metadata does not match current attempt",
        "attempt_id" => payload_attempt_id(payload),
        "idempotency_key" => payload_idempotency_key(payload)
      })

    {state, [event]}
  end

  def ignore_duplicate_step_message(state, step, message, now, reason) do
    step = State.touch_step(step, now)

    state =
      state
      |> State.put_step(step)
      |> Messages.put_message_status(message, step["id"], "ignored", now, %{
        "reason" => reason,
        "step_status" => Map.get(step, "status")
      })
      |> State.put_updated_at(now)

    event =
      Events.workflow_event(:workflow_step_duplicate_message_ignored, step, %{
        "reason" => reason,
        "message_id" => Messages.safe_message_id(message),
        "step_status" => Map.get(step, "status")
      })

    {state, [event]}
  end

  def ignore_terminal_step_event(state, step, event_type, payload, now) do
    step = State.touch_step(step, now)
    state = State.put_step(state, step) |> State.put_updated_at(now)

    event =
      Events.workflow_event(:workflow_step_stale_event_ignored, step, %{
        "reason" => "workflow step already terminal",
        "event_type" => event_type,
        "step_status" => Map.get(step, "status"),
        "attempt_id" => payload_attempt_id(payload),
        "idempotency_key" => payload_idempotency_key(payload)
      })

    {state, [event], []}
  end

  def stale_attempt_output?(step, payload) when is_map(payload) do
    current_attempt = Map.get(step, "current_attempt")
    payload_attempt_id = payload_attempt_id(payload)
    payload_idempotency_key = payload_idempotency_key(payload)

    cond do
      not is_map(current_attempt) and
          (is_binary(payload_attempt_id) or is_binary(payload_idempotency_key)) ->
        true

      not is_map(current_attempt) ->
        false

      is_binary(payload_attempt_id) and
          payload_attempt_id != Map.get(current_attempt, "attempt_id") ->
        true

      is_binary(payload_idempotency_key) and
          payload_idempotency_key != Map.get(current_attempt, "idempotency_key") ->
        true

      true ->
        false
    end
  end

  def stale_attempt_output?(_step, _payload), do: false

  defp payload_attempt_id(payload) when is_map(payload) do
    Map.get(payload, "attempt_id") || Map.get(payload, "mn.workflow.attempt_id")
  end

  defp payload_attempt_id(_payload), do: nil

  defp payload_idempotency_key(payload) when is_map(payload) do
    Map.get(payload, "idempotency_key") || Map.get(payload, "mn.workflow.idempotency_key")
  end

  defp payload_idempotency_key(_payload), do: nil

  @doc false
  def delivery_fence(step, agent_id, message) do
    headers = Message.headers(message)
    attempt = step["current_attempt"]

    cond do
      step["status"] == "retry_wait" ->
        :stale

      is_map(attempt) and
          (headers["mn.workflow.attempt_id"] || headers["mn.workflow.idempotency_key"]) != nil ->
        if stale_attempt_output?(step, headers), do: :stale, else: :sealed

      step["status"] == "queued" and (step["attempt_count"] || 0) > 0 ->
        # Only the ledger's saved entrypoint can open the next attempt. Older
        # queued snapshots store its identity inside the saved message.
        expected =
          step["retry_delivery_id"] || Messages.safe_message_id(Snapshots.step_last_message(step))

        if agent_id == State.primary_agent_id(step) and
             Messages.safe_message_id(message) == expected,
           do: :admit,
           else: :stale

      true ->
        :admit
    end
  end

  def should_start_attempt?(step, _message) do
    not State.step_terminal?(step) and not is_map(Map.get(step, "current_attempt"))
  end

  def step_running_with_different_message?(step, agent_id, message) do
    current = Map.get(step, "current_attempt")

    Map.get(step, "status") == "running" and is_map(current) and
      Map.get(step, "input_agent_id") != agent_id and
      Map.get(current, "message_id") != Messages.safe_message_id(message)
  end
end
