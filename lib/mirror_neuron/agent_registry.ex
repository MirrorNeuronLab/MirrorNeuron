defmodule MirrorNeuron.AgentRegistry do
  alias MirrorNeuron.Builtins

  @builtins %{
    "router" => Builtins.Router,
    "executor" => Builtins.Executor,
    "aggregator" => Builtins.Aggregator,
    "step_join" => Builtins.StepJoin,
    "step_sink" => Builtins.StepSink,
    "step_source" => Builtins.StepSource,
    "sensor" => Builtins.Sensor,
    "module" => Builtins.Module
  }

  def supported_types, do: Map.keys(@builtins)

  def supported_type?(type), do: Map.has_key?(@builtins, type)

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

  def canonical_type(type), do: type
end
