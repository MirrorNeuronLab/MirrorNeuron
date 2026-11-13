defmodule MirrorNeuron.Runtime.LocalRecovery.Settings do
  @moduledoc "Local recovery scan intervals and enablement configuration."

  @default_startup_scan_delay_ms 500
  @default_scan_interval_ms 5_000

  def enabled? do
    env_enabled?("MN_LOCAL_RECOVERY_ENABLED", :local_recovery_enabled, true)
  end

  def startup_delay_ms do
    config_integer(
      "MN_LOCAL_RECOVERY_STARTUP_DELAY_MS",
      :local_recovery_startup_delay_ms,
      @default_startup_scan_delay_ms
    )
  end

  def scan_interval_ms do
    config_integer(
      "MN_LOCAL_RECOVERY_SCAN_INTERVAL_MS",
      :local_recovery_scan_interval_ms,
      @default_scan_interval_ms
    )
  end

  defp config_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> parse_non_negative_integer(value, default)
    end
  end

  defp parse_non_negative_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp env_enabled?(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> false
      value -> value not in ["0", "false", "FALSE", "False", "no", "NO"]
    end
  end
end
