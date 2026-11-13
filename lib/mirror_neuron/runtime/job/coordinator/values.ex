defmodule MirrorNeuron.Runtime.JobCoordinator.Values do
  @moduledoc "Event value normalization and opaque message identifiers."

  def unique_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def stringify(value) when is_binary(value), do: value

  def stringify(value), do: inspect(value)

  def get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      value = Map.get(map, key)
      if value in [nil, ""], do: nil, else: value
    end)
  end

  def get_any(_value, _keys), do: nil

  def stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  def stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value), do: value
end
