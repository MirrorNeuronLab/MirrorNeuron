defmodule MirrorNeuron.BlueprintValidation.Values do
  @moduledoc "Safe input lookup and rule option normalization."

  def path_get(value, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(value, fn part, acc ->
      cond do
        is_map(acc) ->
          map_get(acc, part)

        is_list(acc) and match?({_index, ""}, Integer.parse(part)) ->
          Enum.at(acc, String.to_integer(part))

        true ->
          nil
      end
    end)
  end

  def map_get(map, key) when is_map(map),
    do:
      MirrorNeuron.SafeAccess.map_get(map, key) ||
        MirrorNeuron.SafeAccess.map_get(map, to_string(key))

  def map_get(_map, _key), do: nil

  def map_value(value) when is_map(value), do: value

  def map_value(_value), do: %{}

  def stringify_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  def default(nil, fallback), do: fallback

  def default("", fallback), do: fallback

  def default(value, _fallback), do: value

  def regex_options(rule) do
    if map_get(rule, "ignore_case") == false, do: "", else: "i"
  end

  def rule_name(rule),
    do: map_get(rule, "name") || map_get(rule, "id") || "input validation rule"

  def truthy?(value) when value in [true, 1, "1", "true", "TRUE", "yes", "on"], do: true

  def truthy?(_value), do: false
end
