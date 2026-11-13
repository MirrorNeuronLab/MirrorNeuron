defmodule MirrorNeuron.Scheduler.Placement.Policy do
  @moduledoc "Supported job types and placement strategies."

  @supported_job_types ["service", "batch", "system", "sysbatch"]
  @supported_strategies ["binpack", "spread"]

  def supported_job_types, do: @supported_job_types

  def supported_strategies, do: @supported_strategies

  def normalize_job_type(manifest) do
    type =
      manifest.policies
      |> policy_value("job_type", get_in(manifest.policies || %{}, ["scheduler", "job_type"]))
      |> case do
        nil -> manifest.type || "batch"
        value -> value
      end
      |> to_string()
      |> String.downcase()

    if type in @supported_job_types do
      {:ok, type}
    else
      {:error, "unsupported job_type #{inspect(type)}"}
    end
  end

  def normalize_strategy(manifest) do
    strategy =
      manifest.policies
      |> policy_value(
        "scheduler_strategy",
        get_in(manifest.policies || %{}, ["scheduler", "strategy"])
      )
      |> case do
        nil -> "binpack"
        value -> value
      end
      |> to_string()
      |> String.downcase()

    if strategy in @supported_strategies do
      {:ok, strategy}
    else
      {:error, "unsupported scheduler strategy #{inspect(strategy)}"}
    end
  end

  defp policy_value(nil, _key, default), do: default

  defp policy_value(policies, key, default) when is_map(policies),
    do: Map.get(policies, key, default)

  defp policy_value(_policies, _key, default), do: default
end
