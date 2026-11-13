defmodule MirrorNeuron.Runtime.WorkflowLedger.Events do
  @moduledoc "Builds workflow events and contextual error envelopes."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.WorkflowLedger.State

  def workflow_event(type, step, extra) do
    event =
      %{
        type: type,
        step: step["id"],
        step_id: step["id"],
        agent_id: State.primary_agent_id(step),
        attempt_id: get_in(step, ["current_attempt", "attempt_id"]),
        attempt: get_in(step, ["current_attempt", "attempt"]),
        status: step["status"],
        template_id: Map.get(step, "template_id"),
        region_id: Map.get(step, "region_id"),
        timestamp: Runtime.timestamp()
      }
      |> Map.merge(extra || %{})
      |> maybe_put_workflow_error(type, step)

    event
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_workflow_error(event, type, step) do
    cond do
      Map.get(event, "error") || Map.get(event, :error) ->
        event

      type in [
        :workflow_step_failed,
        :workflow_step_attempt_timed_out,
        :workflow_step_attempt_retry_scheduled,
        :workflow_message_dead_lettered
      ] ->
        reason =
          Map.get(event, "reason") ||
            Map.get(event, :reason) ||
            Map.get(step, "terminal_reason") ||
            "workflow step failed"

        Map.put(event, "error", step_error(reason, step, severity_for_workflow_event(type)))

      true ->
        event
    end
  end

  def step_error(reason, step, opts \\ []) do
    current = Map.get(step, "current_attempt") || %{}
    attempt = Map.get(current, "attempt") || Map.get(step, "attempt_count")

    ErrorEnvelope.normalize(reason,
      component: "workflow_ledger",
      code: Keyword.get(opts, :code),
      severity: Keyword.get(opts, :severity, "ERROR"),
      retryable: Keyword.get(opts, :retryable),
      step_id: Map.get(step, "id"),
      agent_id: Keyword.get(opts, :agent_id, State.primary_agent_id(step)),
      attempt: attempt,
      max_attempts: Map.get(step, "max_attempts")
    )
  end

  defp severity_for_workflow_event(:workflow_step_attempt_retry_scheduled),
    do: [severity: "WARN", retryable: true]

  defp severity_for_workflow_event(_type), do: []

  def beacon_payload(payload, now) do
    %{
      "message" => payload["message"],
      "source" => payload["source"],
      "status" => payload["status"],
      "sequence" => payload["sequence"],
      "last_event_at" => now
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
