defmodule MirrorNeuron.Builtins.Aggregator do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config,
       messages: [],
       complete_on_message: Map.get(node.config, "complete_on_message", false),
       complete_after: Map.get(node.config, "complete_after")
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    payload = payload(message) || %{}
    messages = state.messages ++ [payload]
    next_state = %{state | messages: messages}

    actions = [
      {:event, :aggregator_received, %{"count" => length(messages)}}
    ]

    if should_complete?(next_state, messages) do
      result = aggregate(messages, state.config, payload)

      completion_actions =
        maybe_emit_aggregate(state.config, result) ++ maybe_complete_job(state.config, result)

      {:ok, next_state, actions ++ completion_actions}
    else
      {:ok, next_state, actions}
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

  defp maybe_complete_job(config, result) do
    default =
      case Map.fetch(config, "output_message_type") do
        {:ok, _message_type} -> false
        :error -> true
      end

    if Map.get(config, "complete_job", default) do
      [{:complete_job, result}]
    else
      []
    end
  end

  defp should_complete?(state, messages) do
    state.complete_on_message or
      (is_integer(state.complete_after) and state.complete_after > 0 and
         length(messages) >= state.complete_after)
  end
end
