defmodule MirrorNeuron.Execution.LeaseManager.Settings do
  @moduledoc "Normalizes executor pool capacities and queue limits."

  @default_pool "default"

  def normalize_capacities(capacities) when is_map(capacities) do
    capacities
    |> Enum.map(fn {pool, capacity} ->
      {normalize_pool(pool), normalize_capacity(capacity)}
    end)
    |> Enum.reject(fn {_pool, capacity} -> is_nil(capacity) end)
    |> Enum.into(%{})
    |> case do
      %{} = empty when map_size(empty) == 0 -> %{@default_pool => 4}
      pools -> pools
    end
  end

  defp normalize_capacity(capacity) when is_integer(capacity) and capacity > 0, do: capacity

  defp normalize_capacity(_capacity), do: nil

  def normalize_pool(pool) when is_atom(pool), do: Atom.to_string(pool)

  def normalize_pool(pool) when is_binary(pool) and pool != "", do: pool

  def normalize_pool(_pool), do: @default_pool

  def normalize_node(node) when is_atom(node), do: Atom.to_string(node)

  def normalize_node(node) when is_binary(node), do: node

  def normalize_node(node), do: to_string(node)

  def queue_timeout_ms(state, opts) do
    opts
    |> Keyword.get(:queue_timeout_ms, state.queue_timeout_ms)
    |> normalize_positive_integer(state.queue_timeout_ms)
  end

  def max_queue_length(state, opts) do
    opts
    |> Keyword.get(:max_queue_length, state.max_queue_length)
    |> normalize_nonnegative_integer(state.max_queue_length)
  end

  def parse_positive_integer(env_name, default) do
    case System.get_env(env_name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end

  def config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> normalize_positive_integer(value, default)
    end
  end

  def config_nonnegative_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> normalize_nonnegative_integer(value, default)
    end
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_nonnegative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_nonnegative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_nonnegative_integer(_value, default), do: default
end
