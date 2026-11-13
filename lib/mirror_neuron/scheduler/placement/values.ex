defmodule MirrorNeuron.Scheduler.Placement.Values do
  @moduledoc "Normalizes untrusted node advertisement values without coercing objects to strings."

  def number_value(value) when is_integer(value), do: value

  def number_value(value) when is_float(value), do: value

  def number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _rest} -> number
      :error -> nil
    end
  end

  def number_value(_value), do: nil

  def map_get(map, key), do: MirrorNeuron.SafeAccess.map_get(map, key)

  # Node advertisements are supplied by SDKs as untrusted JSON-like data.  In
  # particular, older advertisements used `%{}` for an empty profile set.
  # Capability and profile fields are list-shaped, so objects are not valid
  # entries and must not be coerced through `String.Chars`.

  def list_value(value) when is_list(value) do
    Enum.flat_map(value, &list_item_value/1)
  end

  def list_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def list_value(value) when is_nil(value), do: []

  def list_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: [to_string(value)]

  def list_value(_value), do: []

  defp list_item_value(value) when is_binary(value), do: [value]

  defp list_item_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: [to_string(value)]

  defp list_item_value(_value), do: []

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

  def get_path(value, []), do: value

  def get_path(map, [part | rest]) when is_map(map) do
    map
    |> map_get(part)
    |> get_path(rest)
  end

  def get_path(_value, _parts), do: nil
end
