defmodule MirrorNeuron.AgentTemplates.Stream do
  alias MirrorNeuron.AgentTemplates.Generic

  def init(node, opts \\ []) do
    {:ok,
     Generic.defaults(node, %{
       chunks_received: 0,
       items_seen: 0,
       stream_open?: false,
       stream_id: Map.get(node.config, "stream_id")
     })
     |> Map.merge(Keyword.get(opts, :state, %{}))}
  end

  def observe_chunk(chunk_count, state, opts \\ []) do
    items_seen = state.items_seen + chunk_count
    next_state = %{state | chunks_received: state.chunks_received + 1, items_seen: items_seen}
    event_type = Keyword.get(opts, :event_type, :stream_chunk_processed)

    {:ok, next_state,
     [
       {:event, event_type,
        %{"chunks_received" => next_state.chunks_received, "items_seen" => items_seen}}
     ]}
  end
end
