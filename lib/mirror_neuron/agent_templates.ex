defmodule MirrorNeuron.AgentTemplates do
  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.AgentTemplates

  @templates %{
    "generic" => AgentTemplates.Generic,
    "stream" => AgentTemplates.Stream,
    "map" => AgentTemplates.Map,
    "reduce" => AgentTemplates.Reduce,
    "batch" => AgentTemplates.Batch
  }

  @compatibility_aliases %{
    "accumulator" => "reduce"
  }

  @agent_template_support %{
    "router" => ["generic", "map"],
    "executor" => ["generic", "stream", "map", "reduce", "batch"],
    "aggregator" => ["generic", "reduce"],
    "sensor" => ["generic"],
    "module" => ["generic", "stream", "map", "reduce", "batch"]
  }

  def default_type, do: "generic"

  def supported_types, do: Map.keys(@templates)

  def supported_type?(type) do
    type
    |> canonical_type()
    |> then(&Map.has_key?(@templates, &1))
  end

  def fetch(type) do
    type
    |> canonical_type()
    |> then(&Map.fetch(@templates, &1))
  end

  def fetch!(type) do
    case fetch(type) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "unsupported agent template #{inspect(type)}"
    end
  end

  def canonical_type(nil), do: default_type()
  def canonical_type(""), do: default_type()
  def canonical_type(type) when is_atom(type), do: type |> Atom.to_string() |> canonical_type()
  def canonical_type(type) when is_binary(type), do: Map.get(@compatibility_aliases, type, type)
  def canonical_type(_type), do: default_type()

  def supported_for_agent_type?(template_type, agent_type) do
    template_type = canonical_type(template_type)
    agent_type = AgentRegistry.canonical_type(agent_type)

    template_type in Map.get(@agent_template_support, agent_type, [default_type()])
  end
end
