defmodule MirrorNeuron.AgentTemplates.Accumulator do
  alias MirrorNeuron.AgentTemplates.Reduce

  def init(node, opts \\ []), do: Reduce.init(node, opts)
  def collect(message, state, opts \\ []), do: Reduce.collect(message, state, opts)
  def should_complete?(state, messages), do: Reduce.should_complete?(state, messages)
end
