defmodule MirrorNeuron.AgentTemplates.Map do
  alias MirrorNeuron.AgentTemplates.Generic

  def init(node, opts \\ []) do
    {:ok,
     Generic.defaults(node, %{
       processed: 0
     })
     |> Map.merge(Keyword.get(opts, :state, %{}))}
  end

  def record_transform(state, opts \\ []) do
    next_state = %{state | processed: Map.get(state, :processed, 0) + 1}
    event_type = Keyword.get(opts, :event_type, :map_transformed)
    {:ok, next_state, [{:event, event_type, %{"processed" => next_state.processed}}]}
  end
end
