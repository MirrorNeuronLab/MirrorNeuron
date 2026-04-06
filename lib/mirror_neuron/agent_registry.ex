defmodule MirrorNeuron.AgentRegistry do
  alias MirrorNeuron.Builtins

  @builtins %{
    "router" => Builtins.Router,
    "executor" => Builtins.Executor,
    "aggregator" => Builtins.Aggregator,
    "sensor" => Builtins.Sensor,
    "module" => Builtins.Module
  }

  @compatibility_aliases %{
    "relay" => "router",
    "sandbox_worker" => "executor",
    "collector" => "aggregator"
  }

  def supported_types, do: Map.keys(@builtins)

  def supported_type?(type),
    do: Map.has_key?(@builtins, type) or Map.has_key?(@compatibility_aliases, type)

  def fetch(type) do
    type
    |> canonical_type()
    |> then(&Map.fetch(@builtins, &1))
  end

  def fetch!(type) do
    case fetch(type) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "unsupported agent_type #{inspect(type)}"
    end
  end

  def canonical_type(type), do: Map.get(@compatibility_aliases, type, type)
end
