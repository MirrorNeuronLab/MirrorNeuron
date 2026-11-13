defmodule MirrorNeuron.Scheduler.Schedules.Records do
  @moduledoc "Records dispatch outcomes and updates schedule lifecycle bookkeeping."

  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Scheduler.Schedules.State
  alias MirrorNeuron.Scheduler.Schedules.Windows

  @terminal_statuses ["completed", "failed", "cancelled"]

  def update_after_dispatch(
        schedule,
        dispatch_id,
        run_id,
        instance,
        metadata,
        started,
        state_lock
      ) do
    now = Map.get(started, :submitted_at) || Runtime.timestamp()
    window_end_at = Windows.window_end_at(schedule, now)

    dispatch =
      %{
        "dispatch_id" => dispatch_id,
        "job_id" => schedule["job_id"] || run_id,
        "run_id" => run_id,
        "status" => "submitted",
        "action" => started.action,
        "scheduled_for" => instance["scheduled_for"],
        "reason" => instance["reason"],
        "submitted_at" => now,
        "window_end_at" => window_end_at,
        "metadata" => metadata
      }
      |> maybe_put("replaced_run_ids", started.replaced_run_ids)
      |> maybe_put("cleanup_deferred", started.cleanup_deferred)
      |> maybe_put("cleanup_pending_nodes", started.cleanup_pending_nodes)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    State.mutate_schedule_with_lock(schedule["schedule_id"], state_lock, fn current ->
      if Enum.any?(
           current["dispatches"] || [],
           &(&1["dispatch_id"] == dispatch_id and &1["status"] in ["submitted", "window_closed"])
         ) do
        current
      else
        current
        |> prune_inactive_run_ids()
        |> prepend_dispatch(dispatch)
        |> Map.update("active_run_ids", [run_id], &Enum.uniq([run_id | &1]))
        |> increment_counter("dispatched")
        |> maybe_complete_one_shot()
      end
    end)
  end

  def update_after_dispatch_failure(schedule, dispatch_id, instance, reason, state_lock) do
    now = Runtime.timestamp()

    error =
      ErrorEnvelope.normalize(reason,
        component: "schedule_dispatcher",
        code: "scheduler.dispatch.failed",
        severity: "ERROR"
      )

    dispatch = %{
      "dispatch_id" => dispatch_id,
      "status" => "failed",
      "scheduled_for" => instance["scheduled_for"],
      "reason" => ErrorEnvelope.desc(error),
      "status_reason" => ErrorEnvelope.desc(error),
      "error" => error,
      "submitted_at" => now
    }

    State.mutate_schedule_with_lock(schedule["schedule_id"], state_lock, fn current ->
      current
      |> prune_inactive_run_ids()
      |> prepend_dispatch(dispatch)
      |> increment_counter("failed")
    end)
  end

  def update_after_dispatch_blocked(schedule, dispatch_id, instance, reason, state_lock) do
    now = Runtime.timestamp()

    dispatch = %{
      "dispatch_id" => dispatch_id,
      "job_id" => schedule["job_id"],
      "status" => "blocked",
      "action" => "blocked",
      "scheduled_for" => instance["scheduled_for"],
      "reason" => to_string(reason),
      "status_reason" => to_string(reason),
      "submitted_at" => now
    }

    State.mutate_schedule_with_lock(schedule["schedule_id"], state_lock, fn current ->
      current
      |> prepend_dispatch(dispatch)
      |> Map.put("last_blocked_reason", to_string(reason))
      |> increment_counter("blocked")
    end)
  end

  defp maybe_complete_one_shot(%{"kind" => kind} = schedule)
       when kind in ["delayed", "resource_wait"] do
    schedule
    |> Map.put("enabled", false)
    |> Map.put("status", "completed")
    |> Map.put("next_run_at", nil)
  end

  defp maybe_complete_one_shot(schedule), do: schedule

  defp prune_inactive_run_ids(schedule) do
    active_run_ids =
      schedule
      |> Map.get("active_run_ids", [])
      |> Enum.filter(&active_run_id?/1)

    Map.put(schedule, "active_run_ids", active_run_ids)
  end

  defp active_run_id?(run_id) when is_binary(run_id) do
    case RedisStore.fetch_job(run_id) do
      {:ok, %{"status" => status}} -> status not in @terminal_statuses
      {:error, reason} when is_binary(reason) -> not String.contains?(reason, "was not found")
      {:error, _reason} -> true
    end
  end

  defp active_run_id?(_run_id), do: false

  def increment_counter(schedule, key) do
    counters = Map.get(schedule, "counters", %{})
    Map.put(schedule, "counters", Map.update(counters, key, 1, &((&1 || 0) + 1)))
  end

  defp prepend_dispatch(schedule, dispatch) do
    Map.update(schedule, "dispatches", [dispatch], fn dispatches ->
      [dispatch | dispatches] |> Enum.take(50)
    end)
  end

  defp maybe_put(map, _key, value) when value in [nil, [], false], do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
