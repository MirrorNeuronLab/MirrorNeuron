defmodule MirrorNeuron.ModelServices.Values do
  @moduledoc "Service metadata, tags and environment normalization."

  @default_node_name "mirror_neuron"

  def stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  def stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)

  def stringify_keys(value), do: value

  def normalize_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_meta(meta) when is_map(meta), do: stringify_keys(meta)

  def normalize_meta(_meta), do: %{}

  def service_model_key(service, meta, tags) do
    normalized_map_value(meta, "model_id") ||
      normalized_map_value(meta, "model") ||
      normalized_map_value(service, "model") ||
      Enum.find_value(tags, fn tag ->
        case String.split(to_string(tag), ":", parts: 2) do
          ["model-id", value] -> normalize_id_part(value)
          ["model", value] -> normalize_id_part(value)
          _ -> nil
        end
      end)
  end

  defp normalize_id_part(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.:-]+/, "-")
    |> case do
      "" -> nil
      text -> text
    end
  end

  def normalized_map_value(map, key) when is_map(map) do
    map
    |> Map.get(key)
    |> case do
      nil ->
        nil

      value ->
        value
        |> to_string()
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end
    end
  end

  def normalized_map_value(_map, _key), do: nil

  def split_env_list(nil), do: []

  def split_env_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def normalized_env(env, key) do
    env
    |> Map.get(key)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  def node_prefix(node_name) do
    node_name
    |> to_string()
    |> String.split("@", parts: 2)
    |> case do
      [prefix, _host] when prefix != "" -> prefix
      _ -> @default_node_name
    end
  end
end
