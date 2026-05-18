defmodule MirrorNeuron.ResourceAdmission do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.Config
  alias MirrorNeuron.Resource

  def check(snapshot \\ hardware_info()) do
    if enabled?() do
      case violations(snapshot) do
        [] ->
          :ok

        violations ->
          reason = format_reason(violations)

          Logger.warning(
            "MirrorNeuron is not accepting a new job because local resources are overloaded: #{reason}"
          )

          {:error, "resource_overloaded: #{reason}"}
      end
    else
      :ok
    end
  end

  def violations(snapshot) do
    snapshot
    |> List.wrap()
    |> Enum.flat_map(&resource_violations/1)
  end

  def thresholds do
    %{
      cpu_load_ratio: float_env("MN_MAX_CPU_LOAD_RATIO") || Resource.limit_ratio(:cpu),
      memory_used_ratio: float_env("MN_MAX_MEMORY_USED_RATIO") || Resource.limit_ratio(:memory),
      gpu_utilization_ratio:
        float_env("MN_MAX_GPU_UTILIZATION_RATIO") || Resource.limit_ratio(:gpu),
      gpu_memory_used_ratio:
        float_env("MN_MAX_GPU_MEMORY_USED_RATIO") || Resource.limit_ratio(:gpu)
    }
  end

  def enabled? do
    Config.boolean("MN_RESOURCE_ADMISSION_ENABLED", :resource_admission_enabled)
  rescue
    _ ->
      System.get_env("MN_RESOURCE_ADMISSION_ENABLED", "true") not in [
        "0",
        "false",
        "FALSE",
        "False",
        ""
      ]
  end

  defp resource_violations(snapshot) when is_map(snapshot) do
    thresholds = thresholds()

    []
    |> maybe_violation(
      :cpu,
      get_in(snapshot, [:cpu, :load_ratio]) || get_in(snapshot, ["cpu", "load_ratio"]),
      thresholds.cpu_load_ratio
    )
    |> maybe_violation(
      :memory,
      get_in(snapshot, [:memory, :used_ratio]) || get_in(snapshot, ["memory", "used_ratio"]),
      thresholds.memory_used_ratio
    )
    |> Kernel.++(gpu_violations(snapshot, thresholds))
  end

  defp resource_violations(_snapshot), do: []

  defp gpu_violations(snapshot, thresholds) do
    gpus = Map.get(snapshot, :gpu) || Map.get(snapshot, "gpu") || []

    gpus
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {gpu, index} ->
      []
      |> maybe_violation(
        :"gpu_#{index}_utilization",
        map_get(gpu, :utilization_ratio),
        thresholds.gpu_utilization_ratio
      )
      |> maybe_violation(
        :"gpu_#{index}_memory",
        map_get(gpu, :memory_used_ratio),
        thresholds.gpu_memory_used_ratio
      )
    end)
  end

  defp maybe_violation(acc, _resource, nil, _threshold), do: acc
  defp maybe_violation(acc, _resource, _value, nil), do: acc

  defp maybe_violation(acc, resource, value, threshold) when value > threshold do
    [%{resource: resource, value: value, threshold: threshold} | acc]
  end

  defp maybe_violation(acc, _resource, _value, _threshold), do: acc

  defp map_get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_get(_other, _key), do: nil

  defp format_reason(violations) do
    violations
    |> Enum.reverse()
    |> Enum.map(fn violation ->
      "#{violation.resource}=#{Float.round(violation.value, 3)} threshold=#{violation.threshold}"
    end)
    |> Enum.join(", ")
  end

  defp float_env(env_name) do
    case System.get_env(env_name) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Float.parse(value) do
          {float, ""} -> float
          {float, _rest} -> float
          :error -> raise ArgumentError, "#{env_name} must be a number"
        end
    end
  end

  defp hardware_info do
    :mirror_neuron
    |> Application.get_env(:hardware_module, Hardware)
    |> apply(:info, [])
  end
end
