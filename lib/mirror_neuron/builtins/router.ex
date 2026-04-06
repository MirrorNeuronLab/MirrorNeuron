defmodule MirrorNeuron.Builtins.Router do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node), do: {:ok, %{node_id: node.node_id, forwarded: 0, config: node.config}}

  @impl true
  def handle_message(message, state, _context) do
    emit_type = Map.get(state.config, "emit_type", type(message))
    payload = payload(message)

    {:ok, %{state | forwarded: state.forwarded + 1},
     [
       {:emit, emit_type, payload,
        [
          class: MirrorNeuron.Message.class(message),
          headers: headers(message),
          artifacts: artifacts(message),
          stream: stream(message),
          content_type: MirrorNeuron.Message.content_type(message),
          content_encoding: MirrorNeuron.Message.content_encoding(message)
        ]}
     ]}
  end
end
