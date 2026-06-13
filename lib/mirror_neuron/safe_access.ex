defmodule MirrorNeuron.SafeAccess do
  @moduledoc false

  @node_name_pattern ~r/^[A-Za-z0-9_.:-]+@[A-Za-z0-9_.:-]+$/

  def map_get(map, key, default \\ nil)

  def map_get(map, key, default) when is_map(map) do
    case map_fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def map_get(_map, _key, default), do: default

  def map_fetch(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      is_binary(key) ->
        fetch_existing_atom_key(map, key)

      is_atom(key) ->
        Map.fetch(map, Atom.to_string(key))

      true ->
        :error
    end
  end

  def map_fetch(_map, _key), do: :error

  def keyword_get(opts, key, default \\ nil)

  def keyword_get(opts, key, default) when is_list(opts) do
    cond do
      is_atom(key) ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> value
          :error -> list_key_get(opts, Atom.to_string(key), default)
        end

      is_binary(key) ->
        case list_key_fetch(opts, key) do
          {:ok, value} ->
            value

          :error ->
            case existing_atom(key) do
              {:ok, atom} -> Keyword.get(opts, atom, default)
              :error -> default
            end
        end

      true ->
        default
    end
  end

  def keyword_get(_opts, _key, default), do: default

  def node_name_to_atom(value) when is_atom(value), do: {:ok, value}

  def node_name_to_atom(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, :empty_node_name}

      byte_size(value) > 255 ->
        {:error, :node_name_too_long}

      not Regex.match?(@node_name_pattern, value) ->
        {:error, :invalid_node_name}

      true ->
        {:ok, String.to_atom(value)}
    end
  end

  def node_name_to_atom(_value), do: {:error, :invalid_node_name}

  def node_name_to_atom!(value) do
    case node_name_to_atom(value) do
      {:ok, node} ->
        node

      {:error, reason} ->
        raise ArgumentError, "invalid Erlang node name #{inspect(value)}: #{reason}"
    end
  end

  def nonempty_binary_to_atom(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :empty_atom}
      byte_size(value) > 255 -> {:error, :atom_too_long}
      true -> {:ok, String.to_atom(value)}
    end
  end

  def nonempty_binary_to_atom(value) when is_atom(value), do: {:ok, value}
  def nonempty_binary_to_atom(_value), do: {:error, :invalid_atom}

  defp fetch_existing_atom_key(map, key) do
    with {:ok, atom} <- existing_atom(key),
         {:ok, value} <- Map.fetch(map, atom) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp existing_atom(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  defp list_key_get(opts, key, default) do
    case list_key_fetch(opts, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp list_key_fetch(opts, key) do
    case List.keyfind(opts, key, 0) do
      {^key, value} -> {:ok, value}
      nil -> :error
    end
  end
end
