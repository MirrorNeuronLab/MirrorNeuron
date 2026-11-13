defmodule MirrorNeuron.Scheduler.Schedules.Eligibility do
  @moduledoc "Checks schedule ownership, overlap and resource readiness."

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.SchedulePolicy
  alias MirrorNeuron.Scheduler

  @terminal_statuses ["completed", "failed", "cancelled"]

  def eligible?(current, :manual, _instance), do: schedule_owner?(current)

  def eligible?(current, trigger, instance) do
    schedule_owner?(current) and (service_schedule?(current) or not overlap_blocked?(current)) and
      case trigger do
        {:event, event} ->
          SchedulePolicy.event_matches?(current, event)

        {:due, now} ->
          not SchedulePolicy.missed?(current, now) and
            instance in SchedulePolicy.due_instances(current, now) and
            (current["kind"] != "resource_wait" or match?({:ok, _}, resource_wait_ready?(current)))
      end
  end

  def schedule_owner?(%{"owner_node" => owner}) when is_binary(owner) and owner != "" do
    owner == to_string(MirrorNeuron.Cluster.NodeAdapter.self())
  end

  def schedule_owner?(_schedule), do: true

  def overlap_blocked?(%{"prohibit_overlap" => true} = schedule) do
    schedule
    |> Map.get("active_run_ids", [])
    |> Enum.any?(fn job_id ->
      case RedisStore.fetch_job(job_id) do
        {:ok, %{"status" => status}} -> status not in @terminal_statuses
        {:error, reason} -> reason != :not_found and reason != "job #{job_id} was not found"
        _ -> true
      end
    end)
  end

  def overlap_blocked?(_schedule), do: false

  def service_schedule?(schedule) do
    schedule["target_type"] == "service"
  end

  def maybe_attach_resource_availability(%{"kind" => "resource_wait"} = schedule, manifest) do
    case Scheduler.availability(manifest) do
      {:ok, availability} ->
        {:ok, Map.put(schedule, "resource_availability", availability)}

      {:blocked, availability} ->
        {:ok, Map.put(schedule, "resource_availability", availability)}

      {:error, %{"reason" => reason} = availability} ->
        {:error,
         "resource requirements cannot be satisfied by the current cluster: #{reason} (#{availability["status"]})"}
    end
  end

  def maybe_attach_resource_availability(schedule, _manifest), do: {:ok, schedule}

  def resource_wait_ready?(schedule) do
    case Manifest.load(Map.get(schedule, "manifest", %{})) do
      {:ok, manifest} -> Scheduler.availability(manifest)
      {:error, reason} -> {:error, availability_error(reason)}
    end
  end

  def availability_error(%{} = availability), do: availability

  def availability_error(reason) do
    %{
      "status" => "not_runnable",
      "reason" => reason_to_string(reason)
    }
  end

  def reason_to_string(reason) when is_binary(reason), do: reason

  def reason_to_string(reason), do: inspect(reason)
end
