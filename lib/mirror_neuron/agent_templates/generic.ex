defmodule MirrorNeuron.AgentTemplates.Generic do
  def defaults(node, state \\ %{}) do
    Map.merge(
      %{
        config: node.config,
        template: Map.get(node, :type, "generic")
      },
      state
    )
  end
end
