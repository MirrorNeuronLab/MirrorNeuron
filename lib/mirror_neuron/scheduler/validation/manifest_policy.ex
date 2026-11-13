defmodule MirrorNeuron.Scheduler.ManifestPolicy do
  @moduledoc "Validates placement policy, scheduled launches and event triggers in executable manifests."

  alias MirrorNeuron.Runtime.SchedulePolicy
  alias MirrorNeuron.Manifest.Values

  def validate_scheduler_policy(errors, %{policies: policies})
      when is_map(policies) do
    scheduler = Map.get(policies, "scheduler")

    job_type =
      Map.get(policies, "job_type") ||
        MirrorNeuron.SafeAccess.map_get(scheduler, "job_type")

    strategy =
      Map.get(policies, "scheduler_strategy") ||
        MirrorNeuron.SafeAccess.map_get(scheduler, "strategy")

    errors
    |> Values.maybe_add_error(
      not is_nil(scheduler) and not is_map(scheduler),
      "policies.scheduler must be an object"
    )
    |> Values.maybe_add_error(
      not supported?(job_type, MirrorNeuron.Scheduler.supported_job_types()),
      "unsupported job_type #{inspect(job_type)}"
    )
    |> Values.maybe_add_error(
      not supported?(strategy, MirrorNeuron.Scheduler.supported_strategies()),
      "unsupported scheduler strategy #{inspect(strategy)}"
    )
  end

  def validate_scheduler_policy(errors, _manifest), do: errors

  defp supported?(nil, _values), do: true
  defp supported?(value, values) when is_binary(value), do: String.downcase(value) in values

  defp supported?(value, values) when is_atom(value),
    do: supported?(Atom.to_string(value), values)

  defp supported?(_value, _values), do: false

  def validate_node_scheduling(errors, manifest) do
    scheduling_errors =
      Enum.flat_map(manifest.nodes, fn node ->
        []
        |> Values.maybe_collect_error(
          not is_map(node.resources),
          "resources for node #{node.node_id} must be an object"
        )
        |> Values.maybe_collect_error(
          not (is_list(node.constraints) or is_map(node.constraints)),
          "constraints for node #{node.node_id} must be a list or object"
        )
      end)

    Values.add_errors(errors, scheduling_errors)
  end

  def validate_schedule(errors, manifest) do
    schedule_errors =
      case manifest.schedule do
        schedule when schedule in [%{}, nil] ->
          []

        schedule ->
          case SchedulePolicy.normalize(schedule, manifest) do
            {:ok, _normalized} -> []
            {:error, errors} -> Enum.map(errors, &"schedule: #{&1}")
          end
      end

    trigger_errors =
      manifest.triggers
      |> Enum.flat_map(fn trigger ->
        case SchedulePolicy.normalize(Map.merge(trigger, %{"kind" => "event"}), manifest) do
          {:ok, _normalized} ->
            []

          {:error, errors} ->
            Enum.map(
              errors,
              &"trigger #{trigger["name"] || trigger["event_type"] || "unknown"}: #{&1}"
            )
        end
      end)

    Values.add_errors(errors, schedule_errors ++ trigger_errors)
  end
end
