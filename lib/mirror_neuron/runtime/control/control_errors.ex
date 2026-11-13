defmodule MirrorNeuron.Runtime.ControlErrors do
  @moduledoc "Stable, human-readable descriptions of runtime control failures."

  @doc false
  def error_message({:job_not_running, job_id}),
    do: "job #{job_id} is not running in the connected cluster"

  def error_message({:job_registry_unavailable, job_id, reason}),
    do: "job registry was unavailable while looking up job #{job_id}: #{inspect(reason)}"

  def error_message({:runtime_lookup_unavailable, job_id, reason}),
    do: "runtime metadata was unavailable while looking up job #{job_id}: #{inspect(reason)}"

  def error_message({:cluster_job_control_unavailable, job_id, node_name, reason}),
    do:
      "cluster job control was unavailable for job #{job_id} on #{node_name}: #{inspect(reason)}"

  def error_message({:redis_primary_unavailable, reason}),
    do: "Redis primary was unavailable: #{inspect(reason)}"

  def error_message(:pause_cleanup_pending),
    do: "The service is still pausing. Resume it after cleanup completes."

  def error_message(:retry_pause_cleanup),
    do: "Pause cleanup failed. Retry pause before resuming."

  def error_message({:job_call_timeout, job_id, timeout_ms}),
    do: "timed out calling job #{job_id} after #{timeout_ms}ms"

  def error_message({:job_cancelling, job_id}),
    do: "job #{job_id} has a durable cancellation in progress"

  def error_message({:job_call_failed, job_id, reason}),
    do: "job #{job_id} call failed: #{inspect(reason)}"

  def error_message({:agent_not_running, details}) do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    retry_attempts = detail(details, "retry_attempts") || 0

    "agent #{agent_id} is not running for job #{job_id} after #{retry_attempts} retries"
  end

  def error_message({:agent_unavailable, details}) do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    reason = detail(details, "reason") || detail(details, "error") || "unavailable"

    "agent #{agent_id} is unavailable for job #{job_id}: #{reason}"
  end

  def error_message({:agent_registry_unavailable, details}) do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    reason = detail(details, "reason") || detail(details, "error") || "registry unavailable"

    "agent registry was unavailable while looking up #{agent_id} for job #{job_id}: #{reason}"
  end

  def error_message({kind, message}) when kind in [:run_retry_blocked, :invalid_run_retry],
    do: message

  def error_message({kind, details}) when kind in [:backpressure, :retry_later] do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    retry_after_ms = detail(details, "retry_after_ms")

    retry_suffix =
      if is_nil(retry_after_ms), do: "", else: "; retry after #{retry_after_ms}ms"

    "agent #{agent_id} for job #{job_id} is applying backpressure#{retry_suffix}"
  end

  def error_message({:invalid_live_input, reason}), do: to_string(reason)

  def error_message({:inactive_run, status}), do: "run is inactive (status: #{status})"

  def error_message({:service_run_exists, run_ids}) do
    "MN_SERVICE_RUN_EXISTS: type: service job already has a run (#{Enum.join(run_ids, ", ")}); resume, pause, cancel, delete, or explicitly replace it"
  end

  def error_message({:admission_blocked, receipt}) do
    "placement_failed: resources are currently unavailable" <>
      MirrorNeuron.Scheduler.AdmissionProblem.encode_rejection(receipt["blockers"] || [])
  end

  def error_message({:resource_requirement_unmet, blockers}) do
    "placement_failed: resource requirements are not met" <>
      MirrorNeuron.Scheduler.AdmissionProblem.encode(blockers)
  end

  def error_message(:replacement_requires_service_job),
    do: "replace_existing_run is valid only for a type: service job"

  def error_message(:replacement_run_id_required),
    do: "a fresh explicit run_id is required when replacing a service run"

  def error_message(:replacement_run_id_must_be_fresh),
    do: "the replacement run_id must differ from every run being replaced"

  def error_message({:service_run_cleanup_failed, run_id, reason}),
    do: "failed to clean service run #{run_id}: #{error_message(reason)}"

  def error_message({:service_schedule_blocked, reason}),
    do: "service schedule is blocked: #{reason}"

  def error_message(reason) when is_binary(reason), do: reason

  def error_message(reason) when is_atom(reason), do: Atom.to_string(reason)

  def error_message(reason), do: inspect(reason)

  defp detail(details, key) when is_map(details) do
    Map.get(details, key) || Map.get(details, String.to_atom(key))
  end

  defp detail(_details, _key), do: nil
end
