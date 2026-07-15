defmodule MirrorNeuron.Builtins.StepSink do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Builtins.StepContract
  alias MirrorNeuron.Message

  @impl true
  def init(node) do
    {:ok, %{config: node.config, completed: false, seen_message_ids: [], attempt_id: nil}}
  end

  @impl true
  def handle_message(message, state, _context) do
    payload = payload(message) || %{}
    attempt_id = StepContract.metadata(payload)["attempt_id"]
    state = reset_for_attempt(state, attempt_id)
    message_id = Message.id(message)

    if state.completed or message_id in state.seen_message_ids do
      {:ok, state, [{:event, :step_sink_duplicate_ignored, event_payload(state)}]}
    else
      artifacts = StepContract.artifacts(payload, artifacts(message))
      metadata = StepContract.metadata(payload)
      flow_output = StepContract.output_payload(payload)

      outputs =
        StepContract.resolve_fields(Map.get(state.config, "fields", %{}), %{
          "flow_output" => flow_output
        })

      case StepContract.validate_schema(outputs, Map.get(state.config, "schema", %{})) do
        :ok ->
          result = %{
            "step_id" => Map.fetch!(state.config, "step_id"),
            "outputs" => outputs,
            "artifacts" => artifacts,
            "_mn_step" => metadata
          }

          actions = [
            {:event, :step_sink_completed, event_payload(state)},
            {:emit, Map.fetch!(state.config, "output_message_type"), result,
             [artifacts: artifacts]},
            {:complete_step, result}
          ]

          {:ok,
           %{state | completed: true, seen_message_ids: [message_id | state.seen_message_ids]},
           actions}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp event_payload(state) do
    %{"step_id" => Map.get(state.config, "step_id"), "completed" => state.completed}
  end

  defp reset_for_attempt(%{attempt_id: nil} = state, attempt_id) do
    %{state | attempt_id: attempt_id}
  end

  defp reset_for_attempt(%{attempt_id: attempt_id} = state, attempt_id), do: state

  defp reset_for_attempt(state, attempt_id) do
    %{state | completed: false, seen_message_ids: [], attempt_id: attempt_id}
  end
end
