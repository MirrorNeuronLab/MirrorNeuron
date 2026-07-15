defmodule MirrorNeuron.Builtins.StepJoin do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Builtins.StepContract
  alias MirrorNeuron.Message

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config,
       outputs: %{},
       seen_message_ids: [],
       emitted: false,
       attempt_id: nil
     }}
  end

  @impl true
  def handle_message(message, state, context) do
    if Map.get(state.config, "fail_on_message") == true do
      {:error, Map.get(state.config, "failure_reason", "step guard failed"), state}
    else
      receive_output(message, state, context)
    end
  end

  defp receive_output(message, state, context) do
    payload = payload(message) || %{}
    attempt_id = StepContract.metadata(payload)["attempt_id"]
    state = reset_for_attempt(state, attempt_id)
    message_id = Message.id(message)
    source = Message.from(message)

    cond do
      state.emitted ->
        {:ok, state, [{:event, :step_join_duplicate_ignored, event_payload(state)}]}

      message_id in state.seen_message_ids or Map.has_key?(state.outputs, source) ->
        {:ok, state, [{:event, :step_join_duplicate_ignored, event_payload(state)}]}

      true ->
        next_state = %{
          state
          | outputs: Map.put(state.outputs, source, payload),
            seen_message_ids: [message_id | state.seen_message_ids]
        }

        if complete?(next_state) do
          result = join_result(next_state, context)

          {:ok, %{next_state | emitted: true},
           [
             {:event, :step_join_completed, event_payload(next_state)},
             {:emit, Map.fetch!(state.config, "output_message_type"), result,
              [artifacts: result["artifacts"]]}
           ]}
        else
          {:ok, next_state, [{:event, :step_join_waiting, event_payload(next_state)}]}
        end
    end
  end

  defp complete?(state) do
    case Map.get(state.config, "completion_mode", "all") do
      "first" -> map_size(state.outputs) > 0
      _ -> Enum.all?(expected_sources(state.config), &Map.has_key?(state.outputs, &1))
    end
  end

  defp join_result(state, context) do
    if Map.get(state.config, "passthrough") == true do
      state.outputs
      |> Map.values()
      |> List.first(%{})
    else
      named_join_result(state, context)
    end
  end

  defp named_join_result(state, context) do
    expected = expected_sources(state.config)
    output_keys = Map.get(state.config, "output_keys", %{})

    outputs =
      Map.new(expected, fn source ->
        key = Map.get(output_keys, source, source)
        {key, StepContract.output_payload(state.outputs[source])}
      end)

    artifacts =
      expected
      |> Enum.flat_map(&StepContract.artifacts(state.outputs[&1], []))
      |> Enum.uniq()

    metadata =
      expected
      |> Enum.find_value(%{}, fn source ->
        metadata = StepContract.metadata(state.outputs[source])
        if map_size(metadata) > 0, do: metadata
      end)

    %{
      "agent_id" => context.node.node_id,
      "outputs" => outputs,
      "artifacts" => artifacts,
      "_mn_step" => metadata
    }
  end

  defp expected_sources(config) do
    config
    |> Map.get("expected_sources", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp event_payload(state) do
    expected_count =
      if Map.get(state.config, "completion_mode") == "first" do
        1
      else
        length(expected_sources(state.config))
      end

    %{
      "expected_count" => expected_count,
      "received_count" => map_size(state.outputs),
      "emitted" => state.emitted
    }
  end

  defp reset_for_attempt(%{attempt_id: nil} = state, attempt_id) do
    %{state | attempt_id: attempt_id}
  end

  defp reset_for_attempt(%{attempt_id: attempt_id} = state, attempt_id), do: state

  defp reset_for_attempt(state, attempt_id) do
    %{state | outputs: %{}, seen_message_ids: [], emitted: false, attempt_id: attempt_id}
  end
end
