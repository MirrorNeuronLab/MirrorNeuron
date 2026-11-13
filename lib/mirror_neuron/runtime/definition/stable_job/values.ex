defmodule MirrorNeuron.Runtime.StableJob.Values do
  @moduledoc "Normalizes definition configuration maps and recursively merges run overlays."

  def stringify(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {to_string(key), stringify(child)} end)

  def stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  def stringify(value), do: value

  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, old, new -> deep_merge(old, new) end)
  end

  def deep_merge(_left, right), do: right

  def maybe_put(map, _key, nil), do: map

  def maybe_put(map, key, value), do: Map.put(map, key, stringify(value))
end
