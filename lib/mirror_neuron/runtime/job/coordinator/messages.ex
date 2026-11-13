defmodule MirrorNeuron.Runtime.JobCoordinator.Messages do
  @moduledoc "Initial and external input envelopes with the current attempt fence."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobCoordinator.Values
  alias MirrorNeuron.Runtime.LiveInput
  alias MirrorNeuron.Runtime.WorkflowLedger

  def seed_initial_entrypoints(state) do
    inputs = state.manifest.initial_inputs

    Enum.reduce_while(state.runtime_entrypoints, :ok, fn agent_id, :ok ->
      source_agent_id = Map.get(state.source_agent_ids, agent_id, agent_id)

      payloads =
        Map.get(inputs, agent_id) ||
          Map.get(inputs, source_agent_id) ||
          Map.get(inputs, "__entrypoints__") ||
          [%{}]

      result =
        Enum.reduce_while(payloads, :ok, fn payload, :ok ->
          message =
            Message.new(
              state.job_id,
              "runtime",
              agent_id,
              "init",
              payload,
              class: "command",
              correlation_id: Values.unique_id()
            )

          message = WorkflowLedger.decorate_message(state.workflow_state, agent_id, message)
          message = put_attempt_epoch(message, state)

          case Runtime.deliver(state.job_id, agent_id, message) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def build_external_message(state, agent_id, message) do
    if LiveInput.command?(state.manifest.contract, agent_id, message) do
      Message.new(state.job_id, "external", agent_id, message["type"], message["payload"],
        class: "command",
        message_id: message["message_id"],
        correlation_id: message["message_id"],
        headers: message["headers"]
      )
    else
      if envelope_message?(message) do
        Message.normalize!(
          message,
          job_id: state.job_id,
          from: "external",
          to: agent_id,
          type: "command",
          class: "command",
          correlation_id: Values.unique_id()
        )
      else
        {type, body} = external_message_body(message)

        Message.new(
          state.job_id,
          "external",
          agent_id,
          type,
          body,
          class: "command",
          correlation_id: Values.unique_id()
        )
      end
    end
    |> put_attempt_epoch(state)
  end

  defp envelope_message?(message) when is_map(message),
    do: Map.has_key?(message, "envelope") or Map.has_key?(message, :envelope)

  defp envelope_message?(_message), do: false

  defp external_message_body(%{"type" => type, "payload" => body}) when is_binary(type),
    do: {type, body}

  defp external_message_body(%{type: type, payload: body}) when is_binary(type),
    do: {type, body}

  defp external_message_body(message), do: {"command", message}

  def put_attempt_epoch(message, state) do
    case get_in(Keyword.get(state.opts, :job_lease, %{}), ["epoch"]) do
      epoch when is_integer(epoch) ->
        Map.update(message, "headers", %{"mn.attempt_epoch" => epoch}, fn headers ->
          Map.put(headers || %{}, "mn.attempt_epoch", epoch)
        end)

      _epoch ->
        message
    end
  end
end
