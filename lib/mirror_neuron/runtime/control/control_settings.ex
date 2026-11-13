defmodule MirrorNeuron.Runtime.ControlSettings do
  @moduledoc "Validated timeouts for public runtime control calls."

  @default_job_call_timeout_ms 15_000
  @default_cancel_job_call_timeout_ms 5_000

  def job_call_timeout_ms,
    do:
      config_positive_integer(
        "MN_JOB_CALL_TIMEOUT_MS",
        :job_call_timeout_ms,
        @default_job_call_timeout_ms
      )

  def cancel_job_call_timeout_ms,
    do:
      config_positive_integer(
        "MN_CANCEL_JOB_CALL_TIMEOUT_MS",
        :cancel_job_call_timeout_ms,
        @default_cancel_job_call_timeout_ms
      )

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> app_positive_integer(key, default)
      "" -> app_positive_integer(key, default)
      value -> positive_integer(value, app_positive_integer(key, default))
    end
  end

  defp app_positive_integer(key, default) do
    case Application.get_env(:mirror_neuron, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp positive_integer(value, default) do
    case parse_integer(value, default) do
      parsed when is_integer(parsed) and parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default
end
