defmodule MirrorNeuron.Builtins.Aggregator do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config,
       messages: [],
       seen_agent_ids: [],
       complete_on_message: Map.get(node.config, "complete_on_message", false),
       complete_after: Map.get(node.config, "complete_after")
     }}
  end

  @impl true
  def handle_message(message, state, context) do
    payload = payload(message) || %{}
    agent_id = if is_map(payload), do: Map.get(payload, "agent_id"), else: nil

    if is_binary(agent_id) and agent_id in state.seen_agent_ids do
      {:ok, state, [{:event, :aggregator_duplicate_ignored, %{"agent_id" => agent_id}}]}
    else
      messages = state.messages ++ [payload]

      next_state =
        if is_binary(agent_id) do
          %{state | messages: messages, seen_agent_ids: state.seen_agent_ids ++ [agent_id]}
        else
          %{state | messages: messages}
        end

      actions = [
        {:event, :aggregator_received, %{"count" => length(messages)}}
      ]

      if should_complete?(next_state, messages) do
        result = aggregate(messages, state.config, payload)

        completion_actions =
          maybe_complete_step(context, result) ++
            maybe_emit_aggregate(state.config, result) ++ maybe_complete_run(state.config, result)

        {:ok, next_state, actions ++ completion_actions}
      else
        {:ok, next_state, actions}
      end
    end
  end

  defp aggregate(messages, _config, last_message) do
    %{"messages" => messages, "count" => length(messages), "last_message" => last_message}
  end

  defp maybe_emit_aggregate(config, result) do
    case Map.fetch(config, "output_message_type") do
      {:ok, message_type} when is_binary(message_type) and message_type != "" ->
        [
          {:emit, message_type, result,
           [
             class: "event",
             headers: %{
               "schema_ref" => "com.mirrorneuron.aggregator.result",
               "schema_version" => "1.0.0"
             }
           ]}
        ]

      _ ->
        []
    end
  end

  defp maybe_complete_run(config, result) do
    if Map.get(config, "terminal_sink", false) and Map.get(config, "complete_run", false) do
      [{:complete_run, result}]
    else
      []
    end
  end

  defp maybe_complete_step(context, result) do
    case Map.get(context, :workflow) do
      workflow when is_map(workflow) and map_size(workflow) > 0 -> [{:complete_step, result}]
      _other -> []
    end
  end

  defp should_complete?(state, messages) do
    state.complete_on_message or
      (is_integer(state.complete_after) and state.complete_after > 0 and
         length(messages) >= state.complete_after)
  end
end
