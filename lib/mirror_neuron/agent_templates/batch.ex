defmodule MirrorNeuron.AgentTemplates.Batch do
  alias MirrorNeuron.AgentTemplates.Generic

  def init(node, opts \\ []) do
    {:ok,
     Generic.defaults(node, %{
       batch: [],
       batch_size: Map.get(node.config, "batch_size", 10),
       flushed_batches: 0
     })
     |> Map.merge(Keyword.get(opts, :state, %{}))}
  end

  def push(item, state, opts \\ []) do
    next_batch = state.batch ++ [item]
    next_state = %{state | batch: next_batch}
    event_type = Keyword.get(opts, :event_type, :batch_buffered)

    if length(next_batch) >= state.batch_size do
      flushed_state = %{next_state | batch: [], flushed_batches: state.flushed_batches + 1}

      {:flush, next_batch, flushed_state,
       [
         {:event, event_type,
          %{"size" => length(next_batch), "flushed_batches" => flushed_state.flushed_batches}}
       ]}
    else
      {:cont, next_state, [{:event, event_type, %{"size" => length(next_batch)}}]}
    end
  end
end
