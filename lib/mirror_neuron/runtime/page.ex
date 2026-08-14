defmodule MirrorNeuron.Runtime.Page do
  @moduledoc false

  @default_size 50
  @max_size 200

  def paginate(items, opts, collection, filters, key_fun) when is_list(items) do
    page_size = opts |> Keyword.get(:page_size, @default_size) |> normalize_size()
    ordered = Enum.sort_by(items, key_fun)

    with {:ok, cursor} <- decode_cursor(Keyword.get(opts, :page_token), collection, filters) do
      upper = cursor && cursor["upper"] || key_for(List.last(ordered), key_fun)
      after_key = cursor && cursor["after"]

      eligible =
        Enum.filter(ordered, fn item ->
          key = key_for(item, key_fun)
          (is_nil(after_key) or key > after_key) and (is_nil(upper) or key <= upper)
        end)

      selected = Enum.take(eligible, page_size)
      has_more = length(eligible) > length(selected)

      next_page_token =
        if has_more and selected != [] do
          encode_cursor(collection, filters, key_for(List.last(selected), key_fun), upper)
        end

      {:ok, selected, next_page_token}
    end
  end

  defp normalize_size(value) when is_integer(value), do: value |> max(1) |> min(@max_size)
  defp normalize_size(_), do: @default_size

  defp key_for(nil, _key_fun), do: nil
  defp key_for(item, key_fun), do: item |> key_fun.() |> List.wrap() |> Enum.map(&to_string/1)

  defp encode_cursor(collection, filters, after_key, upper) do
    %{
      "collection" => collection,
      "filters" => filters,
      "after" => after_key,
      "upper" => upper
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil, _collection, _filters), do: {:ok, nil}
  defp decode_cursor("", _collection, _filters), do: {:ok, nil}

  defp decode_cursor(token, collection, filters) when is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, cursor} when is_map(cursor) <- Jason.decode(json),
         true <- cursor["collection"] == collection,
         true <- cursor["filters"] == filters,
         true <- is_list(cursor["after"]),
         true <- is_list(cursor["upper"]) do
      {:ok, cursor}
    else
      _ -> {:error, :invalid_page_token}
    end
  end

  defp decode_cursor(_token, _collection, _filters), do: {:error, :invalid_page_token}
end

