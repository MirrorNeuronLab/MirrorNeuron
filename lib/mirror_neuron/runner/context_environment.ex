defmodule MirrorNeuron.Runner.ContextEnvironment do
  @moduledoc false

  @keys ~w(MN_CONTEXT_ADDR MN_CONTEXT_AUTH_TOKEN MN_CONTEXT_OBSERVABILITY MN_CONTEXT_TOKEN_COUNTER_FACTORY)

  # A node-local Membrane endpoint must use that execution node's credential.
  # Submission environments may originate on another independently installed node.
  def bind(environment, runtime_environment \\ System.get_env()) do
    if Enum.any?(@keys, &Map.has_key?(environment, &1)) do
      local = Map.take(runtime_environment, @keys)

      if local["MN_CONTEXT_ADDR"] in [nil, ""] or
           local["MN_CONTEXT_AUTH_TOKEN"] in [nil, ""] do
        raise ArgumentError,
              "execution node requires a configured Membrane endpoint and authentication"
      end

      Map.merge(Map.drop(environment, @keys), local)
    else
      environment
    end
  end
end
