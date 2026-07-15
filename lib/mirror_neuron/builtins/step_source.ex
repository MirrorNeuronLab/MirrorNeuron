defmodule MirrorNeuron.Builtins.StepSource do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Builtins.StepContract
  alias MirrorNeuron.Message

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config,
       run_inputs: nil,
       upstream_outputs: %{},
       upstream_artifacts: [],
       seen_message_ids: [],
       dispatched: false,
       attempt_id: nil
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    attempt_id = Map.get(Message.headers(message), "mn.workflow.attempt_id")
    state = reset_for_attempt(state, attempt_id)
    message_id = Message.id(message)

    if message_id in state.seen_message_ids do
      {:ok, state, [{:event, :step_source_duplicate_ignored, event_payload(state)}]}
    else
      payload = payload(message) || %{}
      metadata = StepContract.metadata(payload)
      required = required_upstreams(state.config)
      producer = if is_map(payload), do: Map.get(payload, "step_id"), else: nil

      run_inputs =
        state.run_inputs ||
          Map.get(metadata, "run_inputs") ||
          if(required == [], do: StepContract.initial_input_payload(payload), else: %{})

      upstream_outputs =
        if is_binary(producer) and producer in required do
          Map.put(state.upstream_outputs, producer, StepContract.output_payload(payload))
        else
          state.upstream_outputs
        end

      next_state = %{
        state
        | run_inputs: run_inputs,
          upstream_outputs: upstream_outputs,
          upstream_artifacts:
            Enum.uniq(
              state.upstream_artifacts ++ StepContract.artifacts(payload, artifacts(message))
            ),
          seen_message_ids: Enum.uniq(state.seen_message_ids ++ [message_id])
      }

      maybe_dispatch(next_state, required)
    end
  end

  defp maybe_dispatch(%{dispatched: true} = state, _required) do
    {:ok, state, [{:event, :step_source_already_dispatched, event_payload(state)}]}
  end

  defp maybe_dispatch(state, required) do
    if Enum.all?(required, &Map.has_key?(state.upstream_outputs, &1)) do
      context = %{
        "run_inputs" => state.run_inputs || %{},
        "upstream_outputs" => state.upstream_outputs
      }

      outputs = StepContract.resolve_fields(Map.get(state.config, "fields", %{}), context)

      case StepContract.validate_schema(outputs, Map.get(state.config, "schema", %{})) do
        :ok ->
          metadata = %{
            "step_id" => Map.get(state.config, "step_id"),
            "run_inputs" => state.run_inputs || %{},
            "step_input" => outputs,
            "attempt_id" => state.attempt_id,
            "upstream_steps" => required
          }

          result = %{
            "outputs" => outputs,
            "artifacts" => state.upstream_artifacts,
            "_mn_step" => metadata
          }

          actions = [
            {:event, :step_source_dispatched, event_payload(state)},
            {:emit, Map.fetch!(state.config, "output_message_type"), result,
             [artifacts: state.upstream_artifacts]}
          ]

          {:ok, %{state | dispatched: true}, actions}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:ok, state, [{:event, :step_source_waiting, event_payload(state)}]}
    end
  end

  defp required_upstreams(config) do
    config
    |> Map.get("required_upstreams", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp event_payload(state) do
    %{
      "step_id" => Map.get(state.config, "step_id"),
      "received_upstream_count" => map_size(state.upstream_outputs),
      "dispatched" => state.dispatched
    }
  end

  defp reset_for_attempt(%{attempt_id: nil} = state, attempt_id) do
    %{state | attempt_id: attempt_id}
  end

  defp reset_for_attempt(%{attempt_id: attempt_id} = state, attempt_id), do: state

  defp reset_for_attempt(state, attempt_id) do
    %{
      state
      | run_inputs: nil,
        upstream_outputs: %{},
        upstream_artifacts: [],
        seen_message_ids: [],
        dispatched: false,
        attempt_id: attempt_id
    }
  end
end
