defmodule MirrorNeuron.BlueprintValidation.Requirements do
  @moduledoc "Checks hardware requirements without bypassing hard GPU constraints."

  alias MirrorNeuron.BlueprintValidation.Capacity
  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.HardwareRequirements
  alias MirrorNeuron.BlueprintValidation.InputRules
  alias MirrorNeuron.BlueprintValidation.Reports
  alias MirrorNeuron.BlueprintValidation.Values

  def check_requirements(manifest, snapshot \\ hardware_info()) do
    requirements = Values.map_value(manifest.requirements)

    if InputRules.force?(manifest) and
         not HardwareRequirements.hard_gpu_requirement?(requirements) do
      :ok
    else
      case requirement_violations(requirements, snapshot) do
        [] ->
          :ok

        issues ->
          {:error, "requirements_not_met: " <> Jason.encode!(Reports.validation_report(issues))}
      end
    end
  end

  def requirement_violations(requirements, _snapshot) when map_size(requirements) == 0,
    do: []

  def requirement_violations(requirements, snapshot) do
    capacity = Capacity.capacity(snapshot)

    []
    |> maybe_requirement_violation(
      "cpu",
      Capacity.min_value(requirements, "cpu"),
      capacity.cpu_cores,
      "cores"
    )
    |> maybe_requirement_violation(
      "gpu",
      Capacity.min_value(requirements, "gpu"),
      capacity.gpu_count,
      "GPU(s)"
    )
    |> maybe_requirement_violation(
      "memory",
      Capacity.min_size_gb(requirements, "memory"),
      capacity.memory_gb,
      "GB"
    )
    |> maybe_requirement_violation(
      "disk",
      Capacity.min_size_gb(requirements, "disk"),
      capacity.disk_gb,
      "GB"
    )
    |> maybe_gpu_requirement_violation(requirements, snapshot)
    |> Enum.reverse()
  end

  defp maybe_gpu_requirement_violation(errors, requirements, snapshot) do
    case HardwareRequirements.gpu_requirement_issue(requirements, snapshot) do
      nil ->
        errors

      issue ->
        [
          Reports.issue(
            issue.code,
            issue.message,
            help: issue.help,
            source: "requirements",
            path: "gpu",
            expected: issue.expected,
            actual: issue.actual
          )
          | errors
        ]
    end
  end

  defp maybe_requirement_violation(errors, _name, nil, _actual, _unit), do: errors

  defp maybe_requirement_violation(errors, name, minimum, actual, unit) when actual < minimum do
    [
      Reports.issue(
        "requirements.#{name}_insufficient",
        "#{name} requires at least #{minimum} #{unit}, found #{actual}",
        help:
          "Run this blueprint on a machine with at least #{minimum} #{unit} of #{name}, lower the blueprint requirement, or use --force intentionally.",
        source: "requirements",
        path: name,
        expected: %{"resource" => name, "minimum" => minimum, "unit" => unit},
        actual: %{"resource" => name, "available" => actual, "unit" => unit}
      )
      | errors
    ]
  end

  defp maybe_requirement_violation(errors, _name, _minimum, _actual, _unit), do: errors

  defp hardware_info do
    MirrorNeuron.Resource.list()
  rescue
    _error ->
      :mirror_neuron
      |> Application.get_env(:hardware_module, Hardware)
      |> apply(:info, [])
  end
end
