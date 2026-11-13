defmodule MirrorNeuron.Monitor.Bounds do
  @moduledoc "Reduces oversized job details while retaining status and artifact references."

  alias MirrorNeuron.Monitor.Compaction

  @max_compact_job_bytes 1_000_000

  def bound_job_details(details, max_bytes \\ @max_compact_job_bytes)

  def bound_job_details(details, max_bytes) when is_map(details) and is_integer(max_bytes) do
    if encoded_size(details) <= max_bytes do
      details
    else
      reduced =
        details
        |> Map.put("recent_events", [])
        |> Map.update("summary", %{}, fn summary ->
          if is_map(summary), do: Map.put(summary, "detail_truncated", true), else: summary
        end)
        |> Map.update("job", %{}, &minimal_job/1)

      if encoded_size(reduced) <= max_bytes do
        reduced
      else
        hard_bound_job_details(reduced)
      end
    end
  end

  def bound_job_details(details, _max_bytes), do: details

  defp minimal_job(job) when is_map(job) do
    job
    |> Map.drop(["result"])
    |> Map.update("workflow_state", nil, &minimal_workflow_state/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp minimal_job(job), do: job

  defp minimal_workflow_state(%{"steps" => steps} = state) when is_map(steps) do
    minimal_steps =
      Map.new(steps, fn {step_id, step} ->
        value =
          if is_map(step) do
            Map.take(step, [
              "id",
              "status",
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

        {step_id, value}
      end)

    state
    |> Map.take(["schema_version", "job_id", "run_id", "status", "created_at", "updated_at"])
    |> Map.put("steps", minimal_steps)
  end

  defp minimal_workflow_state(_state), do: nil

  defp hard_bound_job_details(details) do
    job = Map.get(details, "job", %{})
    workflow_state = Map.get(job, "workflow_state", %{})
    step_count = workflow_state |> Map.get("steps", %{}) |> map_size_or_zero()

    %{
      "job" =>
        job
        |> Map.drop(["workflow_state"])
        |> Map.take([
          "job_id",
          "graph_id",
          "job_name",
          "status",
          "job_type",
          "submitted_at",
          "updated_at",
          "manifest_ref",
          "result_ref",
          "workflow_state_ref",
          "failure"
        ])
        |> Map.put("workflow_step_count", step_count),
      "summary" =>
        details
        |> Map.get("summary", %{})
        |> Map.take([
          "job_id",
          "graph_id",
          "job_name",
          "status",
          "submitted_at",
          "updated_at",
          "failure"
        ])
        |> Map.put("detail_truncated", true),
      "agents" => details |> Map.get("agents", []) |> Enum.take(25) |> Compaction.compact_value(),
      "recent_events" => [],
      "sandboxes" =>
        details |> Map.get("sandboxes", []) |> Enum.take(25) |> Compaction.compact_value()
    }
  end

  defp map_size_or_zero(value) when is_map(value), do: map_size(value)

  defp map_size_or_zero(_value), do: 0

  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()
end
