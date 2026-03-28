defmodule MirrorNeuron.AgentTemplates.Accumulator do
  def init(node, opts \\ []) do
    defaults = %{
      config: node.config,
      messages: [],
      complete_on_message: Keyword.get(opts, :complete_on_message, false),
      complete_after: Map.get(node.config, "complete_after")
    }

    {:ok, Map.merge(defaults, Keyword.get(opts, :state, %{}))}
  end

  def collect(message, state, opts \\ []) do
    payload = MirrorNeuron.Agent.payload(message) || %{}
    messages = state.messages ++ [payload]
    next_state = %{state | messages: messages}
    event_type = Keyword.get(opts, :event_type, :aggregator_received)
    build_result = Keyword.fetch!(opts, :build_result)
    extra_actions = Keyword.get(opts, :extra_actions, [])

    actions =
      [{:event, event_type, %{count: length(messages)}}]
      |> Kernel.++(extra_actions)

    if should_complete?(next_state, messages) do
      {:ok, next_state,
       actions ++ [{:complete_job, build_result.(messages, state.config, payload)}]}
    else
      {:ok, next_state, actions}
    end
  end

  def should_complete?(state, messages) do
    state.complete_on_message or
      (is_integer(state.complete_after) and state.complete_after > 0 and
         length(messages) >= state.complete_after)
  end
end
