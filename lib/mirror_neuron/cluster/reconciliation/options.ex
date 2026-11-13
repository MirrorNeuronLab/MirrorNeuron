defmodule MirrorNeuron.Cluster.Reconciler.Options do
  @moduledoc "Recovery dependencies and serialized boundary values."

  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Persistence.RedisStore

  def redis_store(opts), do: Keyword.get(opts, :redis_store, RedisStore)

  def event_bus(opts), do: Keyword.get(opts, :event_bus, EventBus)

  def dry_run?(opts), do: Keyword.get(opts, :dry_run, false)

  def stringify_result(result) when is_map(result) do
    Enum.into(result, %{}, fn {key, value} -> {to_string(key), stringify_result(value)} end)
  end

  def stringify_result(values) when is_list(values), do: Enum.map(values, &stringify_result/1)

  def stringify_result(value), do: value

  def node_name(node) when is_atom(node), do: Atom.to_string(node)

  def node_name(node) when is_binary(node), do: node

  def node_name(node), do: to_string(node)
end
