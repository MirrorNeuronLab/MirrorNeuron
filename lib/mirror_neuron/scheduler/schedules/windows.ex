defmodule MirrorNeuron.Scheduler.Schedules.Windows do
  @moduledoc "Closes execution windows while preserving overlapping service runs."

  alias MirrorNeuron.Scheduler.Schedules.Eligibility
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Scheduler.Schedules.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Scheduler.Schedules.State

  @terminal_statuses ["completed", "failed", "cancelled"]

  def process_due_windows(schedules, now) do
    schedules
    |> due_closures(now)
    |> Enum.map(fn {schedule, dispatch, pause?} -> close_window({schedule, dispatch}, pause?) end)
    |> Results.reduce_results()
  end

  @doc "Returns due schedule/dispatch pairs and whether each closes the last service window."
  def due_closures(schedules, now) do
    due = Enum.flat_map(schedules, &due_window_dispatches(&1, now))
    pause_dispatch_ids = service_pause_dispatch_ids(schedules, due, now)

    Enum.map(due, fn {schedule, dispatch} ->
      {schedule, dispatch, MapSet.member?(pause_dispatch_ids, dispatch["dispatch_id"])}
    end)
  end

  defp due_window_dispatches(schedule, now) do
    now_iso = DateTime.to_iso8601(now)

    schedule
    |> Map.get("dispatches", [])
    |> Enum.filter(fn dispatch ->
      dispatch["status"] == "submitted" and
        is_binary(dispatch["window_end_at"]) and
        dispatch["window_end_at"] <= now_iso and
        get_in(schedule, ["window", "end_action"]) in ["cancel", "pause"]
    end)
    |> Enum.map(&{schedule, &1})
  end

  defp service_pause_dispatch_ids(schedules, due, now) do
    now_iso = DateTime.to_iso8601(now)

    open_service_keys =
      schedules
      |> Enum.filter(&Eligibility.service_schedule?/1)
      |> Enum.flat_map(fn schedule ->
        schedule
        |> Map.get("dispatches", [])
        |> Enum.filter(fn dispatch ->
          dispatch["status"] == "submitted" and
            (not is_binary(dispatch["window_end_at"]) or dispatch["window_end_at"] > now_iso)
        end)
        |> Enum.map(&service_window_key(schedule, &1))
      end)
      |> MapSet.new()

    due
    |> Enum.filter(fn {schedule, _dispatch} -> Eligibility.service_schedule?(schedule) end)
    |> Enum.group_by(fn {schedule, dispatch} -> service_window_key(schedule, dispatch) end)
    |> Enum.reduce(MapSet.new(), fn {key, entries}, selected ->
      if MapSet.member?(open_service_keys, key) do
        selected
      else
        {_schedule, dispatch} =
          Enum.max_by(entries, fn {_schedule, item} -> item["window_end_at"] end)

        MapSet.put(selected, dispatch["dispatch_id"])
      end
    end)
  end

  defp service_window_key(schedule, dispatch) do
    {schedule["job_id"], dispatch["run_id"] || dispatch["job_id"]}
  end

  defp close_window({schedule, dispatch}, pause?) do
    run_id = dispatch["run_id"] || dispatch["job_id"]
    service? = Eligibility.service_schedule?(schedule)

    pause_run? =
      if service?, do: pause?, else: get_in(schedule, ["window", "end_action"]) == "pause"

    close_result =
      cond do
        pause_run? -> pause_service_run(run_id)
        service? -> :ok
        is_binary(run_id) -> MirrorNeuron.cancel(run_id)
        true -> :ok
      end

    case close_result do
      :ok -> finish_window_close(schedule, dispatch, run_id, service?, pause_run?)
      {:ok, _status} -> finish_window_close(schedule, dispatch, run_id, service?, pause_run?)
      {:error, reason} -> window_close_failure(schedule, dispatch, reason)
    end
  end

  defp finish_window_close(schedule, dispatch, run_id, service?, pause?) do
    action =
      if pause?,
        do: "paused",
        else: if(service?, do: "kept_running", else: "cancelled")

    State.log_schedule_update_failure(
      schedule["schedule_id"],
      State.mutate_schedule(schedule["schedule_id"], fn current ->
        updated_dispatches =
          Enum.map(current["dispatches"] || [], fn item ->
            if item["dispatch_id"] == dispatch["dispatch_id"] do
              item
              |> Map.put("status", "window_closed")
              |> Map.put("window_action", action)
              |> Map.put("closed_at", Runtime.timestamp())
              |> record_service_pause_action(service?, pause?)
            else
              item
            end
          end)

        current
        |> Map.put("dispatches", updated_dispatches)
        |> maybe_remove_closed_run(run_id, service?, pause?)
      end)
    )

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 0, windows_closed: 1}
  end

  defp window_close_failure(schedule, dispatch, reason) do
    State.log_schedule_update_failure(
      schedule["schedule_id"],
      State.mutate_schedule(schedule["schedule_id"], fn current ->
        updated_dispatches =
          Enum.map(current["dispatches"] || [], fn item ->
            if item["dispatch_id"] == dispatch["dispatch_id"] do
              item
              |> Map.put("window_close_error", Eligibility.reason_to_string(reason))
              |> Map.put("window_close_attempted_at", Runtime.timestamp())
            else
              item
            end
          end)

        Map.put(current, "dispatches", updated_dispatches)
      end)
    )

    %{
      checked: 1,
      dispatched: 0,
      skipped: 0,
      failed: 1,
      missed: 0,
      blocked: 0,
      windows_closed: 0
    }
  end

  defp pause_service_run(run_id) when is_binary(run_id) do
    case RedisStore.fetch_job(run_id) do
      {:ok, %{"status" => status}} when status in ["paused" | @terminal_statuses] ->
        :ok

      {:ok, _run} ->
        MirrorNeuron.pause(run_id)

      {:error, reason} ->
        if missing_job_error?(reason), do: :ok, else: {:error, reason}
    end
  end

  defp pause_service_run(_run_id), do: :ok

  defp missing_job_error?(reason) when is_binary(reason),
    do: String.contains?(reason, "was not found")

  defp missing_job_error?(_reason), do: false

  defp record_service_pause_action(dispatch, true, true) do
    dispatch
    |> Map.put("opening_action", dispatch["action"])
    |> Map.put("action", "paused")
  end

  defp record_service_pause_action(dispatch, _service?, _pause?), do: dispatch

  defp maybe_remove_closed_run(schedule, _run_id, true, false), do: schedule

  defp maybe_remove_closed_run(schedule, run_id, _service?, _pause?) do
    schedule
    |> Map.update("active_run_ids", [], &List.delete(&1, run_id))
  end

  def window_end_at(schedule, submitted_at) do
    duration = get_in(schedule, ["window", "duration_ms"])

    with true <- is_integer(duration) and duration > 0,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(submitted_at) do
      datetime
      |> DateTime.add(duration, :millisecond)
      |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end
end
