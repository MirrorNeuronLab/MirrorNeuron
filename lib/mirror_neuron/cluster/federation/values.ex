defmodule MirrorNeuron.Cluster.FederationRegistry.Values do
  @moduledoc "Federation serialization, timestamps and configurable store boundaries."

  alias MirrorNeuron.Persistence.RedisStore

  def stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  def stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  def stringify_keys(value), do: value

  def timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  def coordination_store do
    Application.get_env(:mirror_neuron, :coordination_store, RedisStore)
  end

  def projection_store do
    Application.get_env(:mirror_neuron, :federation_projection_store, RedisStore)
  end
end
