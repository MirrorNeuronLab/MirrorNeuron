defmodule MirrorNeuron.Cluster.Reconciler.Timing do
  @moduledoc "Recovery due times and bounded retry scheduling."

  @eval_retry_statuses ["pending", "blocked"]

  def due_eval?(eval) do
    Map.get(eval, "status") in @eval_retry_statuses and wait_due?(Map.get(eval, "wait_until"))
  end

  def wait_due?(nil), do: true

  def wait_due?(""), do: true

  def wait_due?(wait_until) when is_binary(wait_until) do
    case DateTime.from_iso8601(wait_until) do
      {:ok, dt, _offset} -> DateTime.compare(dt, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  def wait_due?(_wait_until), do: true

  def recovery_eval_attempt(eval), do: integer_value(Map.get(eval, "attempt"), 0)

  def retry_wait_until(eval, opts) do
    attempt = max(recovery_eval_attempt(eval), 1)

    base =
      Keyword.get(
        opts,
        :retry_base_ms,
        config_positive_integer("MN_RECOVERY_EVAL_RETRY_BASE_MS", 5_000)
      )

    max_delay =
      Keyword.get(
        opts,
        :retry_max_ms,
        config_positive_integer("MN_RECOVERY_EVAL_RETRY_MAX_MS", 60_000)
      )

    delay = bounded_delay(base, attempt - 1, max_delay)
    iso_after(delay)
  end

  # Stop at the cap before constructing an unbounded power from persisted attempts.
  defp bounded_delay(0, _remaining, _cap), do: 0
  defp bounded_delay(delay, _remaining, cap) when delay >= cap, do: cap
  defp bounded_delay(delay, 0, _cap), do: delay
  defp bounded_delay(delay, remaining, cap), do: bounded_delay(delay * 2, remaining - 1, cap)

  defp iso_after(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(delay_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp config_positive_integer(env_name, default) do
    case System.get_env(env_name) do
      nil -> default
      "" -> default
      value -> integer_value(value, default)
    end
  end

  defp integer_value(value, _default) when is_integer(value) and value >= 0, do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default
end
