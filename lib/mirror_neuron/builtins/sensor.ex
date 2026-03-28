defmodule MirrorNeuron.Builtins.Sensor do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config,
       observations: 0,
       complete_after: Map.get(node.config, "complete_after", 1)
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    payload = payload(message) || %{}
    observations = state.observations + 1
    next_state = %{state | observations: observations}
    output_message_type = Map.get(state.config, "output_message_type", "sensor_ready")

    actions = [
      {:event, :sensor_observed, %{"count" => observations}},
      {:emit, output_message_type, payload,
       [
         class: "event",
         headers: headers(message),
         artifacts: artifacts(message),
         stream: stream(message),
         content_type: MirrorNeuron.Message.content_type(message),
         content_encoding: MirrorNeuron.Message.content_encoding(message)
       ]}
    ]

    if observations >= state.complete_after and Map.get(state.config, "complete_job", false) do
      {:ok, next_state,
       actions ++ [{:complete_job, %{"count" => observations, "last_message" => payload}}]}
    else
      {:ok, next_state, actions}
    end
  end
end
