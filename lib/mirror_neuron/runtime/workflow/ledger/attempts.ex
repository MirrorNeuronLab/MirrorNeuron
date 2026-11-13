defmodule MirrorNeuron.Runtime.WorkflowLedger.Attempts do
  @moduledoc "Starts attempts, records failures and prepares bounded retries."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.WorkflowActivity
  alias MirrorNeuron.Runtime.WorkflowLedger.Events
  alias MirrorNeuron.Runtime.WorkflowLedger.Messages
  alias MirrorNeuron.Runtime.WorkflowLedger.Resolution
  alias MirrorNeuron.Runtime.WorkflowLedger.Snapshots
  alias MirrorNeuron.Runtime.WorkflowLedger.State
  alias MirrorNeuron.Runtime.WorkflowLedger.Values
  alias MirrorNeuron.Runtime.WorkflowMessage
  alias MirrorNeuron.Runtime.WorkflowPreparation

  @default_retry_backoff_ms 1_000

  def start_attempt(state, step, agent_id, message, now) do
    metadata = attempt_metadata(state, step, message, now)

    attempt = %{
      "attempt_id" => metadata.attempt_id,
      "attempt" => metadata.attempt_number,
      "agent_id" => agent_id,
      "message_id" => Messages.safe_message_id(message),
      "idempotency_key" => metadata.idempotency_key,
      "started_at" => now,
      "deadline_at" => metadata.deadline_at,
      "heartbeat_deadline_at" => metadata.heartbeat_deadline_at,
      "last_beacon_at" => now,
      "status" => "running"
    }

    decorated = Messages.decorate_step_message(state, step, message, metadata.headers)

    step =
      step
      |> Map.merge(%{
        "status" => "running",
        "started_at" => Map.get(step, "started_at") || now,
        "ended_at" => nil,
        "last_event_at" => now,
        "attempt_count" => metadata.attempt_number,
        "current_attempt" => attempt,
        "retry_delivery_id" => nil,
        "deadline_at" => metadata.deadline_at,
        "heartbeat_deadline_at" => metadata.heartbeat_deadline_at,
        "retry_at" => nil,
        "last_message" => decorated,
        "terminal_reason" => nil,
        "terminal_error" => nil,
        "last_error" => nil
      })
      |> WorkflowPreparation.reset()
      |> Map.drop([
        "inspection",
        "inspection_retry_used",
        "progress_sequences",
        "seen_waits",
        "waiting_id",
        "progress_deadline_at"
      ])
      |> WorkflowActivity.start(now)

    state =
      state
      |> State.put_step(step)
      |> Messages.put_message_status(decorated, step["id"], "running", now, %{
        "attempt_id" => metadata.attempt_id,
        "attempt" => metadata.attempt_number,
        "idempotency_key" => metadata.idempotency_key,
        "from" => Message.from(decorated),
        "to" => Message.to(decorated),
        "type" => Message.type(decorated)
      })
      |> State.put_updated_at(now)

    event =
      Events.workflow_event(:workflow_step_attempt_started, step, %{
        "agent_id" => agent_id,
        "attempt_id" => metadata.attempt_id,
        "attempt" => metadata.attempt_number,
        "deadline_at" => metadata.deadline_at,
        "heartbeat_deadline_at" => metadata.heartbeat_deadline_at,
        "idempotency_key" => metadata.idempotency_key,
        "message_id" => Messages.safe_message_id(decorated)
      })

    {state, [event]}
  end

  def fail_current_attempt(state, %{"current_attempt" => nil} = step, reason, now) do
    error = Events.step_error(reason, step)
    reason = if is_map(reason), do: ErrorEnvelope.desc(error), else: Values.stringify(reason)

    step =
      Map.merge(step, %{
        "last_event_at" => now,
        "terminal_reason" => reason,
        "terminal_error" => error
      })

    state = State.put_step(state, step)
    {state, [], []}
  end

  def fail_current_attempt(state, step, reason, now) do
    current = Map.get(step, "current_attempt") || %{}
    error = Events.step_error(reason, step)
    failure = if is_map(reason), do: error, else: Values.stringify(reason)
    reason = if is_map(reason), do: ErrorEnvelope.desc(error), else: Values.stringify(reason)

    finished_attempt =
      current
      |> Map.merge(%{
        "status" => "failed",
        "ended_at" => now,
        "reason" => reason,
        "error" => error
      })

    attempts = Map.get(step, "attempts", []) ++ [finished_attempt]
    # Closing the failed attempt here prevents handled failures from recording
    # it again when the logical step resolves as partial or skipped.
    step = step |> Map.put("attempts", attempts) |> Map.put("current_attempt", nil)
    attempt_count = Map.get(step, "attempt_count", length(attempts))

    cond do
      attempt_count < Map.get(step, "max_attempts", 1) ->
        retry_at = Values.iso_after_ms(now, retry_delay_ms(step, attempt_count))

        step =
          step
          |> Map.merge(%{
            "status" => "retry_wait",
            "current_attempt" => nil,
            "deadline_at" => nil,
            "heartbeat_deadline_at" => nil,
            "retry_at" => retry_at,
            "last_event_at" => now,
            "terminal_reason" => reason,
            "last_error" => error
          })

        state = State.put_step(state, step) |> State.put_updated_at(now)

        event =
          Events.workflow_event(:workflow_step_attempt_retry_scheduled, step, %{
            "reason" => reason,
            "error" => error,
            "retry_at" => retry_at,
            "next_attempt" => attempt_count + 1,
            "max_attempts" => Map.get(step, "max_attempts", 1)
          })

        {state, [event], []}

      optional_step?(step) ->
        status = optional_resolution_status(step)

        {state, events} =
          Resolution.resolve_step(state, step, status, %{"reason" => reason}, now,
            outcome: "failed"
          )

        failure_event =
          Events.workflow_event(:workflow_step_failed, State.get_step(state, step["id"]), %{
            "reason" => reason,
            "error" => error,
            "status" => status,
            "handled" => true
          })

        {state, [failure_event | events], []}

      true ->
        step =
          step
          |> Map.merge(%{
            "status" => "failed",
            "current_attempt" => nil,
            "deadline_at" => nil,
            "heartbeat_deadline_at" => nil,
            "retry_at" => nil,
            "ended_at" => now,
            "last_event_at" => now,
            "terminal_reason" => reason,
            "terminal_error" => error
          })

        state = State.put_step(state, step) |> State.put_updated_at(now)

        event =
          Events.workflow_event(:workflow_step_failed, step, %{
            "reason" => reason,
            "error" => error,
            "status" => "failed"
          })

        {state, [event], [{:fail_job, step["id"], failure}]}
    end
  end

  def retry_message(state, step, now) do
    case Snapshots.step_last_message(step) do
      message when is_map(message) ->
        attempt_number = Map.get(step, "attempt_count", 0) + 1

        retry_message =
          WorkflowMessage.retry_delivery(
            message,
            workflow_attempt_message_id(state, step, message, attempt_number)
          )

        metadata = attempt_metadata(state, step, retry_message, now)

        decorated = Messages.decorate_step_message(state, step, retry_message, metadata.headers)

        step =
          step
          |> Map.merge(%{
            "status" => "queued",
            "retry_at" => nil,
            "last_event_at" => now,
            "retry_delivery_id" => Messages.safe_message_id(decorated),
            "last_message" => decorated
          })

        {:ok, decorated, step}

      _ ->
        {:error, "workflow retry has no saved message"}
    end
  end

  defp attempt_metadata(state, step, message, now) do
    attempt_number = Map.get(step, "attempt_count", 0) + 1
    attempt_id = attempt_id(step["id"], attempt_number)

    deadline_at = Values.iso_after_seconds_if_configured(now, Map.get(step, "timeout_seconds"))

    heartbeat_deadline_at =
      Values.iso_after_ms_if_configured(now, Map.get(step, "beacon_timeout_ms"))

    idempotency_key =
      step["retry_idempotency_key"] || idempotency_key(state, step["id"], attempt_number, message)

    %{
      attempt_number: attempt_number,
      attempt_id: attempt_id,
      deadline_at: deadline_at,
      heartbeat_deadline_at: heartbeat_deadline_at,
      idempotency_key: idempotency_key,
      headers: %{
        "mn.workflow.attempt_id" => attempt_id,
        "mn.workflow.attempt" => attempt_number,
        "mn.workflow.deadline_at" => deadline_at,
        "mn.workflow.heartbeat_deadline_at" => heartbeat_deadline_at,
        "mn.workflow.idempotency_key" => idempotency_key
      }
    }
  end

  defp optional_step?(step) do
    Map.get(step, "required") == false or
      Map.get(step, "failure_policy") in ["continue_partial", "skip", "continue"]
  end

  defp optional_resolution_status(%{"failure_policy" => "skip"}), do: "skipped"

  defp optional_resolution_status(_step), do: "partial"

  defp retry_delay_ms(step, completed_attempt_count) do
    base = Values.positive_int(Map.get(step, "retry_backoff_ms"), @default_retry_backoff_ms)
    multiplier = Values.positive_number(Map.get(step, "retry_backoff_multiplier"), 2)
    trunc(base * :math.pow(multiplier, max(completed_attempt_count - 1, 0)))
  end

  defp idempotency_key(state, step_id, attempt, message) do
    [
      State.run_id(state),
      step_id,
      attempt,
      Messages.safe_message_id(message) || Values.unique_id()
    ]
    |> Enum.join(":")
  end

  defp attempt_id(step_id, attempt), do: "#{step_id}:attempt:#{attempt}"

  defp workflow_attempt_message_id(state, step, message, attempt_number) do
    [
      "workflow_attempt",
      State.run_id(state),
      step["id"],
      Messages.safe_message_id(message),
      attempt_number
    ]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
