defmodule MirrorNeuron.ServiceCheck.Redaction do
  @moduledoc false

  @sensitive_keys ~w(authorization cookie token access_token api_key key password secret signature sig)

  def value(value), do: do_redact_value(value, "")

  def url(url) do
    uri = URI.parse(to_string(url))

    redacted_query =
      if is_binary(uri.query) and uri.query != "" do
        uri.query
        |> URI.decode_query()
        |> Enum.map(fn {key, value} ->
          if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, value}
        end)
        |> URI.encode_query()
      else
        nil
      end

    %{uri | query: redacted_query}
    |> URI.to_string()
  rescue
    _ -> "[REDACTED_URL]"
  end

  defp do_redact_value(value, path) when is_map(value) do
    Map.new(value, fn {key, item} ->
      key = to_string(key)
      next_path = if path == "", do: key, else: "#{path}.#{key}"
      {key, if(sensitive_key?(key), do: "[REDACTED]", else: do_redact_value(item, next_path))}
    end)
  end

  defp do_redact_value(value, path) when is_list(value),
    do: Enum.map(value, &do_redact_value(&1, path))

  defp do_redact_value(value, path) when is_binary(value) do
    if String.starts_with?(value, ["http://", "https://"]) do
      url(value)
    else
      if sensitive_key?(path), do: "[REDACTED]", else: value
    end
  end

  defp do_redact_value(value, _path), do: value

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_keys, &String.contains?(key, &1))
  end
end
