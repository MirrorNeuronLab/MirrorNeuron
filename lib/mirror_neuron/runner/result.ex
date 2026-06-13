defmodule MirrorNeuron.Runner.Result do
  @moduledoc false

  def sanitize(result) when is_map(result) do
    Enum.into(result, %{}, fn
      {key, value} when is_binary(value) ->
        {key, value |> redact_secrets() |> truncate_artifact()}

      entry ->
        entry
    end)
  end

  def sanitize(result), do: result

  def redact_secrets(text) when is_binary(text) do
    System.get_env()
    |> Enum.filter(fn {key, value} ->
      value != "" and String.match?(key, ~r/(TOKEN|SECRET|KEY|COOKIE|PASSWORD)/i)
    end)
    |> Enum.reduce(text, fn {_key, value}, acc -> String.replace(acc, value, "[REDACTED]") end)
  end

  def redact_secrets(value), do: value

  def truncate_artifact(text) when is_binary(text) do
    max_bytes =
      System.get_env("MN_MAX_ARTIFACT_BYTES", "1048576")
      |> String.to_integer()

    if byte_size(text) > max_bytes do
      binary_part(text, 0, max_bytes) <> "\n[truncated by MN_MAX_ARTIFACT_BYTES]"
    else
      text
    end
  end

  def truncate_artifact(value), do: value
end
