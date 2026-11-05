defmodule MirrorNeuron.Persistence.JobSummary do
  @moduledoc false

  # Pure compact records shared by durable writes and running-job projections.
  # Persisted keys, defaults and terminal failure details belong to this format;
  # Redis keys, fencing and transactions remain in RedisStore.
  def build(job_id, job) do
    %{
      "job_id" => field(job, "job_id") || job_id,
      "graph_id" => field(job, "graph_id"),
      "job_name" => field(job, "job_name"),
      "status" => field(job, "status"),
      "admission" => field(job, "admission"),
      "running_time" => field(job, "running_time"),
      "clock_session" => field(job, "clock_session"),
      "attempt" => field(job, "attempt", 0),
      "attempt_started_at" => field(job, "attempt_started_at"),
      "restart_reason" => field(job, "restart_reason"),
      "recovery_mode" => field(job, "recovery_mode"),
      "job_type" => field(job, "job_type"),
      "submitted_at" => field(job, "submitted_at"),
      "updated_at" => field(job, "updated_at"),
      "placement_policy" => field(job, "placement_policy"),
      "scheduler" => job_scheduler_summary(field(job, "scheduler")),
      "lease_owner" => job_lease_owner(job),
      "requested_recovery_policy" => field(job, "requested_recovery_policy"),
      "recovery_policy" => field(job, "recovery_policy"),
      "reliability" => field(job, "reliability"),
      "restart_policy" => field(job, "restart_policy"),
      "reschedule_policy" => field(job, "reschedule_policy"),
      "policy_state" => field(job, "policy_state"),
      "recovery_status" => field(job, "recovery_status"),
      "recovery_requires_review" => field(job, "recovery_requires_review", false),
      "recovery_reason" => field(job, "recovery_reason"),
      "recovery_hint" => recovery_hint(job),
      "executor_count" => field(job, "executor_count", 0),
      "active_executors" => field(job, "active_executors", 0),
      "nodes" => field(job, "nodes", []),
      "sandbox_names" => field(job, "sandbox_names", []),
      "last_event" => field(job, "last_event"),
      "failure" => failure_summary(job),
      "manifest_ref" => field(job, "manifest_ref"),
      "result_ref" => field(job, "result_ref"),
      "workflow_state_ref" => field(job, "workflow_state_ref"),
      "workflow_state" => workflow_state_summary(field(job, "workflow_state"))
    }
  end

  defp job_scheduler_summary(scheduler) when is_map(scheduler) do
    placements = field(scheduler, "placements", [])

    %{
      "status" => field(scheduler, "status"),
      "job_type" => field(scheduler, "job_type"),
      "strategy" => field(scheduler, "strategy"),
      "mode" => field(scheduler, "mode"),
      "placement_count" => field(scheduler, "placement_count", length(placements)),
      "nodes" =>
        placements
        |> Enum.map(&field(&1, "node"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp job_scheduler_summary(_scheduler), do: nil

  defp job_lease_owner(job) do
    field(job, "lease_owner") ||
      case field(job, "lease") do
        lease when is_map(lease) -> field(lease, "owner_id")
        _lease -> nil
      end
  end

  defp workflow_state_summary(%{"steps" => steps} = state) when is_map(steps) do
    summarized_steps =
      Map.new(steps, fn {step_id, step} ->
        summary =
          if is_map(step) do
            Map.take(step, [
              "id",
              "label",
              "run",
              "status",
              "agent_ids",
              "dynamic_instance",
              "template_id",
              "region_id",
              "patch_id",
              "attempt_count",
              "started_at",
              "ended_at",
              "last_event_at",
              "terminal_outcome",
              "terminal_reason",
              "output_ref"
            ])
          else
            %{"status" => "unknown"}
          end

        {step_id, summary}
      end)

    state
    |> Map.take([
      "schema_version",
      "enabled",
      "job_id",
      "run_id",
      "status",
      "mode",
      "dynamic_enabled",
      "graph_revision",
      "edges",
      "dynamic_regions",
      "dynamic_history",
      "step_order",
      "created_at",
      "updated_at"
    ])
    |> Map.put("steps", summarized_steps)
  end

  defp workflow_state_summary(_state), do: nil

  defp failure_summary(job) do
    result = field(job, "result")

    if field(job, "status") == "failed" and is_map(result) do
      error = field(result, "error")
      error_fields = if is_map(error), do: error, else: %{}

      summary = %{
        "message" => failure_message(error, result),
        "category" => field(error_fields, "category"),
        "component" => field(error_fields, "component"),
        "agent_id" => field(error_fields, "agent_id") || field(result, "agent_id"),
        "step_id" => field(error_fields, "step_id") || field(result, "step_id"),
        "node" => field(error_fields, "node"),
        "retryable" => field(error_fields, "retryable")
      }

      summary
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> case do
        empty when map_size(empty) == 0 -> nil
        bounded -> bounded
      end
    end
  end

  defp failure_message(error, _result) when is_binary(error), do: error

  defp failure_message(error, result) when is_map(error) do
    field(error, "message") || field(error, "description") || field(result, "status_reason")
  end

  defp failure_message(_error, result) do
    field(result, "status_reason") || field(result, "reason")
  end

  defp recovery_hint(job) do
    if field(job, "status") == "failed" and runner_interruption_result?(field(job, "result")) do
      "runner_interruption"
    end
  end

  defp runner_interruption_result?(result) when is_map(result) do
    field(result, "agent_id") == "job_runner" and
      field(result, "error") == "job coordinator exited before terminal state"
  end

  defp runner_interruption_result?(_result), do: false

  defp field(map, name, default \\ nil) when is_map(map) do
    Map.get(map, name, Map.get(map, String.to_atom(name), default))
  end
end
