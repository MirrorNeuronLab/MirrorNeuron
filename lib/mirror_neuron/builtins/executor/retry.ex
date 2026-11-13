defmodule MirrorNeuron.Builtins.Executor.Retry do
  @moduledoc "Transient failure classification, retry limits and execution backoff."

  @transient_markers [
    "h2 protocol error",
    "peer closed connection",
    "status: Unknown",
    "error reading a body from connection",
    "TLS close_notify",
    "transport error",
    "connection reset",
    "connection refused",
    "timed out",
    "agent beacon deadline exceeded",
    "deadline exceeded",
    "artifact_not_ready",
    "unavailable"
  ]

  def max_attempts(config) do
    case Map.get(config, "max_attempts", 1) do
      attempts when is_integer(attempts) and attempts >= 1 -> attempts
      _ -> 1
    end
  end

  def backoff_ms(config, attempt) do
    base =
      case Map.get(config, "retry_backoff_ms", 500) do
        delay when is_integer(delay) and delay >= 0 -> delay
        _ -> 500
      end

    trunc(base * :math.pow(2, max(attempt - 1, 0)))
  end

  def retryable?(%{"retryable" => false}), do: false

  def retryable?(reason) do
    reason
    |> error_blob()
    |> String.downcase()
    |> then(fn blob ->
      Enum.any?(@transient_markers, &String.contains?(blob, String.downcase(&1)))
    end)
  end

  defp error_blob(reason) when is_map(reason) do
    [
      Map.get(reason, "error"),
      Map.get(reason, "logs"),
      Map.get(reason, "raw_output"),
      Map.get(reason, "stderr"),
      Map.get(reason, "stdout"),
      inspect(reason)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      value when is_binary(value) -> value
      value -> inspect(value)
    end)
    |> Enum.join("\n")
  end

  defp error_blob(reason), do: inspect(reason)

  def enrich_error(reason, attempts) when is_map(reason),
    do: Map.put(reason, "attempts", attempts)

  def enrich_error(reason, attempts), do: %{"error" => inspect(reason), "attempts" => attempts}
end
