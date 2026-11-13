defmodule MirrorNeuron.BlueprintValidation.Redaction do
  @moduledoc "Bounds validation diagnostics and strips credentials from values and URLs."

  def redact_value(nil, _path), do: nil

  def redact_value(value, _path) when is_number(value) or is_boolean(value), do: value

  def redact_value(value, path) when is_binary(value) do
    if sensitive_name?(path || "") do
      "[redacted]"
    else
      value
      |> redact_url()
      |> truncate_debug()
    end
  end

  def redact_value(value, path) when is_list(value) do
    value
    |> Enum.take(20)
    |> Enum.map(&redact_value(&1, path))
  end

  def redact_value(value, path) when is_map(value) do
    value
    |> Enum.take(20)
    |> Enum.into(%{}, fn {key, nested} ->
      nested_path = [path, key] |> Enum.reject(&is_nil/1) |> Enum.join(".")
      {to_string(key), redact_value(nested, nested_path)}
    end)
  end

  def redact_value(value, _path), do: inspect(value)

  defp redact_url(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        query =
          (uri.query || "")
          |> URI.decode_query()
          |> Enum.into(%{}, fn {key, query_value} ->
            if sensitive_name?(key), do: {key, "[redacted]"}, else: {key, query_value}
          end)
          |> URI.encode_query()

        %URI{uri | userinfo: nil, query: if(query == "", do: nil, else: query)}
        |> URI.to_string()

      _ ->
        value
    end
  rescue
    _ -> value
  end

  defp sensitive_name?(value) do
    value = String.downcase(to_string(value))

    Enum.any?(
      [
        "password",
        "passwd",
        "secret",
        "token",
        "api_key",
        "apikey",
        "authorization",
        "signature"
      ],
      &String.contains?(value, &1)
    )
  end

  defp truncate_debug(value, limit \\ 2000) do
    value = to_string(value || "")

    if String.length(value) > limit do
      String.slice(value, 0, limit - 20) <> "...[truncated]"
    else
      value
    end
  end
end
