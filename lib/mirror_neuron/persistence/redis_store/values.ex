defmodule MirrorNeuron.Persistence.RedisStore.Values do
  @moduledoc "Normalizes record values and reports corrupt or invalid persistence input."

  def field(map, name, default \\ nil) when is_map(map) do
    Map.get(map, name, Map.get(map, String.to_atom(name), default))
  end

  def decode_json_items(items) do
    items
    |> Enum.map(fn
      nil ->
        nil

      encoded ->
        case Jason.decode(encoded) do
          {:ok, item} -> item
          {:error, _reason} -> nil
        end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def corrupt_json?(%Jason.DecodeError{}), do: true

  def corrupt_json?(_reason), do: false

  def config_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil ->
        Application.get_env(:mirror_neuron, key, default)

      "" ->
        Application.get_env(:mirror_neuron, key, default)

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end

  def validate_identifier(field, value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, "#{field} must be a non-empty string"}
    else
      :ok
    end
  end

  def validate_identifier(field, _value), do: {:error, "#{field} must be a non-empty string"}

  def format_reason(reason) when is_binary(reason), do: reason

  def format_reason(reason), do: inspect(reason)

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

  def parse_integer(value) when is_integer(value), do: value

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def parse_integer(_value), do: nil

  def timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
