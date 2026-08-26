defmodule MirrorNeuron.Runtime.ScheduleDispatcher do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.SchedulePolicy

  @lease_ttl_ms 30_000
  @state_lease_ttl_ms 30_000
  @state_lease_wait_ms 35_000
  @state_lease_retry_ms 10
  @terminal_statuses ["completed", "failed", "cancelled"]

  @doc "Creates a schedule whose target is a stable job."
  def create_job_schedule(job_id, schedule_attrs \\ %{}, opts \\ []) do
    with {:ok, definition} <- StableJob.get(job_id),
         :ok <- ensure_stable_job_active(definition),
         {:ok, manifest} <- Manifest.load(definition["manifest"]),
         {:ok, bundle} <- load_definition_bundle(definition, manifest),
         {:ok, schedule} <- normalize_schedule(bundle, schedule_attrs, opts),
         {:ok, schedule} <- maybe_attach_resource_availability(schedule, manifest) do
      schedule_id = Keyword.get(opts, :schedule_id) || generate_schedule_id()

      record =
        schedule
        |> Map.put("schedule_id", schedule_id)
        |> Map.put("job_id", job_id)
        |> Map.put("owner_node", definition["owner_node"])
        |> Map.put("manifest", definition["manifest"])
        |> Map.put("bundle_ref", definition["bundle_ref"])
        |> Map.put("source", stringify(Keyword.get(opts, :source, %{})))
        |> Map.put("dispatches", [])
        |> Map.put("active_run_ids", [])
        |> Map.put("counters", %{"dispatched" => 0, "missed" => 0, "failed" => 0})

      with {:ok, persisted} <- RedisStore.persist_schedule(schedule_id, record) do
        case StableJob.attach_schedule(job_id, schedule_id) do
          {:ok, _definition} ->
            {:ok, persisted}

          {:error, reason} ->
            _ = RedisStore.delete_schedule(schedule_id)
            {:error, reason}
        end
      end
    end
  end

  defp ensure_stable_job_active(%{"status" => "active"}), do: :ok
  defp ensure_stable_job_active(_definition), do: {:error, :job_not_active}

  def update_schedule(schedule_id, attrs, opts \\ []) do
    mutate_schedule(schedule_id, fn existing ->
      with {:ok, normalized} <-
             existing
             |> Map.merge(stringify(attrs || %{}))
             |> SchedulePolicy.normalize(Map.get(existing, "manifest", %{}), opts) do
        {:ok,
         Map.merge(
           normalized,
           Map.take(existing, [
             "schedule_id",
             "manifest",
             "bundle_ref",
             "source",
             "dispatches",
             "active_run_ids",
             "counters",
             "created_at"
           ])
         )}
      end
    end)
  end

  def pause_schedule(schedule_id, opts \\ []) do
    update_schedule_state(schedule_id, "paused", false, opts)
  end

  def resume_schedule(schedule_id, opts \\ []) do
    mutate_schedule(schedule_id, fn schedule ->
      with {:ok, normalized} <-
             SchedulePolicy.normalize(
               Map.put(schedule, "enabled", true),
               Map.get(schedule, "manifest", %{}),
               opts
             ) do
        {:ok, Map.merge(schedule, normalized)}
      end
    end)
  end

  def delete_schedule(schedule_id, _opts \\ []), do: delete_schedule_locked(schedule_id)

  def get_schedule(schedule_id), do: RedisStore.fetch_schedule(schedule_id)

  def list_schedules(opts \\ []) do
    with {:ok, schedules} <- RedisStore.list_schedules() do
      {:ok, filter_schedules(schedules, opts)}
    end
  end

  def dispatch_schedule(schedule_id, payload \\ %{}, opts \\ []) do
    with {:ok, schedule} <- RedisStore.fetch_schedule(schedule_id) do
      dispatch_with_lease(schedule, %{
        "scheduled_for" => Runtime.timestamp(),
        "reason" => Keyword.get(opts, :reason, "manual"),
        "payload" => stringify(payload || %{})
      })
    end
  end

  def process_due_schedules(now \\ SchedulePolicy.now()) do
    now_iso = DateTime.to_iso8601(now)

    with {:ok, due} <- RedisStore.list_due_schedules(now_iso),
         {:ok, all} <- RedisStore.list_schedules() do
      window_result = process_due_windows(all, now)

      due_result =
        due
        |> Enum.map(&process_due_schedule(&1, now))
        |> reduce_results()

      {:ok, merge_counts(due_result, window_result)}
    end
  end

  def emit_event(event_type, payload \\ %{}, opts \\ []) do
    event_id = Keyword.get(opts, :event_id) || generate_event_id()

    event = %{
      "event_id" => event_id,
      "event_type" => to_string(event_type),
      "source" => Keyword.get(opts, :source, "runtime"),
      "payload" => stringify(payload || %{}),
      "created_at" => Runtime.timestamp()
    }

    with {:ok, persisted} <- RedisStore.append_trigger_event(event_id, event),
         {:ok, schedules} <- RedisStore.list_schedules() do
      matches =
        schedules
        |> Enum.filter(&SchedulePolicy.event_matches?(&1, persisted))
        |> Enum.map(&dispatch_event_schedule(&1, persisted))
        |> reduce_results()

      {:ok, Map.put(matches, :event, persisted)}
    end
  end

  def list_events(opts \\ []) do
    RedisStore.list_trigger_events(Keyword.get(opts, :limit, 100))
  end

  defp normalize_schedule(bundle, attrs, opts) do
    manifest_schedule =
      bundle.manifest
      |> Manifest.to_map()
      |> Map.get("schedule", %{})

    attrs =
      if map_size(stringify(attrs || %{})) == 0 do
        manifest_schedule
      else
        attrs
      end

    SchedulePolicy.normalize(attrs, bundle.manifest, opts)
  end

  defp update_schedule_state(schedule_id, status, enabled, opts) do
    reason = Keyword.get(opts, :reason, "")
    now = Runtime.timestamp()

    mutate_schedule(schedule_id, fn schedule ->
      Map.merge(schedule, %{
        "status" => status,
        "enabled" => enabled,
        "last_status_reason" => reason,
        "updated_at" => now
      })
    end)
  end

  defp process_due_schedule(schedule, now) do
    cond do
      schedule["kind"] == "resource_wait" ->
        process_resource_wait_schedule(schedule, now)

      SchedulePolicy.missed?(schedule, now) ->
        mark_missed(schedule, now)

      overlap_blocked?(schedule) and not service_schedule?(schedule) ->
        mark_blocked(schedule, "overlap")

      true ->
        schedule
        |> SchedulePolicy.due_instances(now)
        |> Enum.map(&dispatch_with_lease(schedule, &1))
        |> reduce_results()
        |> advance_schedule(schedule, now)
    end
  end

  defp dispatch_event_schedule(schedule, event) do
    if overlap_blocked?(schedule) and not service_schedule?(schedule) do
      mark_blocked(schedule, "overlap")
    else
      dispatch_with_lease(schedule, %{
        "scheduled_for" => Runtime.timestamp(),
        "reason" => "event",
        "event" => event
      })
    end
  end

  defp process_resource_wait_schedule(schedule, now) do
    cond do
      overlap_blocked?(schedule) and not service_schedule?(schedule) ->
        postpone_resource_wait(schedule, now, "overlap")

      true ->
        case resource_wait_ready?(schedule) do
          {:ok, availability} ->
            schedule
            |> SchedulePolicy.due_instances(now)
            |> Enum.map(
              &dispatch_with_lease(Map.put(schedule, "resource_availability", availability), &1)
            )
            |> reduce_results()

          {:blocked, availability} ->
            postpone_resource_wait(schedule, now, Map.get(availability, "reason"), availability)

          {:error, availability} ->
            availability = availability_error(availability)
            postpone_resource_wait(schedule, now, Map.get(availability, "reason"), availability)
        end
    end
  end

  defp dispatch_with_lease(schedule, instance) do
    if schedule_owner?(schedule) do
      do_dispatch_with_lease(schedule, instance)
    else
      %{checked: 1, dispatched: 0, skipped: 1, failed: 0, missed: 0, blocked: 0}
    end
  end

  defp do_dispatch_with_lease(schedule, instance) do
    lease_name = "schedule:#{schedule["schedule_id"]}:#{dispatch_token(schedule, instance)}"
    owner = "#{Node.self()}:#{System.unique_integer([:positive])}"

    case RedisStore.acquire_fenced_lease(lease_name, owner, @lease_ttl_ms) do
      {:ok, lease} ->
        try do
          case with_schedule_state_lock(schedule["schedule_id"], fn lock ->
                 with {:ok, current_schedule} <-
                        RedisStore.fetch_schedule(schedule["schedule_id"]) do
                   dispatch_child(current_schedule, instance, lease, lock)
                 end
               end) do
            {:error, reason} ->
              Logger.warning("schedule state lease failed: #{inspect(reason)}")
              %{checked: 1, dispatched: 0, skipped: 0, failed: 1, missed: 0, blocked: 0}

            result ->
              result
          end
        after
          _ = RedisStore.release_ephemeral_fenced_lease(lease_name, owner, lease["epoch"])
        end

      {:error, {:locked, _lease}} ->
        %{checked: 1, dispatched: 0, skipped: 1, failed: 0, missed: 0, blocked: 0}

      {:error, reason} ->
        Logger.warning("schedule lease failed: #{inspect(reason)}")
        %{checked: 1, dispatched: 0, skipped: 0, failed: 1, missed: 0, blocked: 0}
    end
  end

  defp schedule_owner?(%{"owner_node" => owner}) when is_binary(owner) and owner != "" do
    owner == to_string(MirrorNeuron.Cluster.NodeAdapter.self())
  end

  defp schedule_owner?(_schedule), do: true

  defp dispatch_child(schedule, instance, lease, state_lock) do
    dispatch_id = generate_dispatch_id()
    metadata = schedule_dispatch_metadata(schedule, instance, dispatch_id, lease)

    with {:ok, started} <- start_scheduled_run(schedule, metadata) do
      run_id = started.run_id

      log_schedule_update_failure(
        schedule["schedule_id"],
        update_after_dispatch(
          schedule,
          dispatch_id,
          run_id,
          instance,
          metadata,
          started,
          state_lock
        )
      )

      %{checked: 1, dispatched: 1, skipped: 0, failed: 0, missed: 0, blocked: 0}
    else
      {:error, {:service_schedule_blocked, reason}} ->
        log_schedule_update_failure(
          schedule["schedule_id"],
          update_after_dispatch_blocked(schedule, dispatch_id, instance, reason, state_lock)
        )

        %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 1}

      {:error, reason} ->
        log_schedule_update_failure(
          schedule["schedule_id"],
          update_after_dispatch_failure(schedule, dispatch_id, instance, reason, state_lock)
        )

        %{checked: 1, dispatched: 0, skipped: 0, failed: 1, missed: 0, blocked: 0}
    end
  end

  defp start_scheduled_run(%{"job_id" => job_id}, metadata)
       when is_binary(job_id) and job_id != "" do
    StableJob.scheduled_transition(job_id,
      schedule_metadata: metadata,
      inputs: Map.get(metadata, "payload", %{})
    )
  end

  defp start_scheduled_run(schedule, metadata) do
    with {:ok, bundle_or_manifest} <- load_dispatch_bundle(schedule, metadata) do
      case Runtime.start_job(
             dispatch_manifest(bundle_or_manifest),
             dispatch_opts(bundle_or_manifest)
           ) do
        {:ok, run_id, pid} ->
          {:ok,
           %{
             action: "started",
             run_id: run_id,
             status: "pending",
             pid: pid,
             replaced_run_ids: [],
             cleanup_deferred: false,
             cleanup_pending_nodes: []
           }}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp load_dispatch_bundle(schedule, metadata) do
    fingerprint = get_in(schedule, ["bundle_ref", "bundle_fingerprint"])

    case Archive.load(fingerprint) do
      {:ok, %JobBundle{} = bundle} ->
        manifest = put_manifest_dispatch_metadata(bundle.manifest, metadata)
        {:ok, %JobBundle{bundle | manifest: manifest}}

      {:error, _reason} ->
        with {:ok, manifest} <- Manifest.load(Map.get(schedule, "manifest", %{})) do
          {:ok, put_manifest_dispatch_metadata(manifest, metadata)}
        end
    end
  end

  defp dispatch_manifest(%JobBundle{manifest: manifest}), do: manifest
  defp dispatch_manifest(%Manifest{} = manifest), do: manifest

  defp dispatch_opts(%JobBundle{} = bundle), do: [job_bundle: bundle]
  defp dispatch_opts(%Manifest{}), do: []

  defp put_manifest_dispatch_metadata(%Manifest{} = manifest, metadata) do
    next_metadata =
      manifest.metadata
      |> stringify()
      |> Map.put("schedule_dispatch", metadata)

    %{manifest | metadata: next_metadata}
  end

  defp schedule_dispatch_metadata(schedule, instance, dispatch_id, lease) do
    event = Map.get(instance, "event")

    %{
      "schedule_id" => schedule["schedule_id"],
      "schedule_name" => schedule["name"],
      "schedule_kind" => schedule["kind"],
      "dispatch_id" => dispatch_id,
      "scheduled_for" => instance["scheduled_for"],
      "reason" => instance["reason"],
      "payload" => Map.get(instance, "payload", %{}),
      "event" => event,
      "lease" => %{"owner" => lease["owner_id"], "epoch" => lease["epoch"]}
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp update_after_dispatch(
         schedule,
         dispatch_id,
         run_id,
         instance,
         metadata,
         started,
         state_lock
       ) do
    now = Runtime.timestamp()
    window_end_at = window_end_at(schedule, now)

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

    mutate_schedule_with_lock(schedule["schedule_id"], state_lock, fn current ->
      current
      |> prune_inactive_run_ids()
      |> prepend_dispatch(dispatch)
      |> Map.update("active_run_ids", [run_id], &Enum.uniq([run_id | &1]))
      |> increment_counter("dispatched")
      |> maybe_complete_one_shot()
    end)
  end

  defp load_definition_bundle(definition, manifest) do
    fingerprint = get_in(definition, ["bundle_ref", "bundle_fingerprint"])

    case Archive.load(fingerprint) do
      {:ok, %JobBundle{} = bundle} -> {:ok, bundle}
      {:error, _reason} -> {:ok, %JobBundle{manifest: manifest}}
    end
  end

  defp update_after_dispatch_failure(schedule, dispatch_id, instance, reason, state_lock) do
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

    mutate_schedule_with_lock(schedule["schedule_id"], state_lock, fn current ->
      current
      |> prune_inactive_run_ids()
      |> prepend_dispatch(dispatch)
      |> increment_counter("failed")
    end)
  end

  defp update_after_dispatch_blocked(schedule, dispatch_id, instance, reason, state_lock) do
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

    mutate_schedule_with_lock(schedule["schedule_id"], state_lock, fn current ->
      current
      |> prepend_dispatch(dispatch)
      |> Map.put("last_blocked_reason", to_string(reason))
      |> increment_counter("blocked")
    end)
  end

  defp advance_schedule(result, schedule, now) do
    occurrence_consumed =
      result.dispatched > 0 or (service_schedule?(schedule) and result.blocked > 0)

    if occurrence_consumed and schedule["kind"] == "periodic" do
      next_run_at = SchedulePolicy.next_run_at(schedule, DateTime.add(now, 60, :second))

      log_schedule_update_failure(
        schedule["schedule_id"],
        mutate_schedule(schedule["schedule_id"], &Map.put(&1, "next_run_at", next_run_at))
      )
    end

    result
  end

  defp mark_missed(schedule, now) do
    next_run_at = SchedulePolicy.next_run_at(schedule, now)

    log_schedule_update_failure(
      schedule["schedule_id"],
      mutate_schedule(schedule["schedule_id"], fn current ->
        current
        |> Map.put("next_run_at", next_run_at)
        |> Map.put("last_missed_at", DateTime.to_iso8601(now))
        |> increment_counter("missed")
      end)
    )

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 1, blocked: 0}
  end

  defp mark_blocked(schedule, reason) do
    log_schedule_update_failure(
      schedule["schedule_id"],
      mutate_schedule(schedule["schedule_id"], fn current ->
        current
        |> Map.put("last_blocked_reason", reason)
        |> Map.put("updated_at", Runtime.timestamp())
      end)
    )

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 1}
  end

  defp postpone_resource_wait(schedule, now, reason, availability \\ %{}) do
    next_run_at =
      now
      |> DateTime.add(Map.get(schedule, "retry_interval_ms", 30_000), :millisecond)
      |> DateTime.to_iso8601()

    log_schedule_update_failure(
      schedule["schedule_id"],
      mutate_schedule(schedule["schedule_id"], fn current ->
        current
        |> Map.put("next_run_at", next_run_at)
        |> Map.put("last_blocked_reason", reason || "resources unavailable")
        |> Map.put("resource_availability", availability)
        |> Map.put("updated_at", Runtime.timestamp())
        |> increment_counter("blocked")
      end)
    )

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 1}
  end

  defp process_due_windows(schedules, now) do
    due = Enum.flat_map(schedules, &due_window_dispatches(&1, now))
    pause_dispatch_ids = service_pause_dispatch_ids(schedules, due, now)

    due
    |> Enum.map(fn {schedule, dispatch} ->
      close_window(
        {schedule, dispatch},
        MapSet.member?(pause_dispatch_ids, dispatch["dispatch_id"])
      )
    end)
    |> reduce_results()
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
      |> Enum.filter(&service_schedule?/1)
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
    |> Enum.filter(fn {schedule, _dispatch} -> service_schedule?(schedule) end)
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
    service? = service_schedule?(schedule)

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

    log_schedule_update_failure(
      schedule["schedule_id"],
      mutate_schedule(schedule["schedule_id"], fn current ->
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
    log_schedule_update_failure(
      schedule["schedule_id"],
      mutate_schedule(schedule["schedule_id"], fn current ->
        updated_dispatches =
          Enum.map(current["dispatches"] || [], fn item ->
            if item["dispatch_id"] == dispatch["dispatch_id"] do
              item
              |> Map.put("window_close_error", reason_to_string(reason))
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

  defp overlap_blocked?(%{"prohibit_overlap" => true} = schedule) do
    schedule
    |> Map.get("active_run_ids", [])
    |> Enum.any?(fn job_id ->
      case RedisStore.fetch_job(job_id) do
        {:ok, %{"status" => status}} -> status not in @terminal_statuses
        _ -> false
      end
    end)
  end

  defp overlap_blocked?(_schedule), do: false

  defp service_schedule?(schedule) do
    schedule["target_type"] == "service"
  end

  defp window_end_at(schedule, submitted_at) do
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

  defp maybe_complete_one_shot(%{"kind" => kind} = schedule)
       when kind in ["delayed", "resource_wait"] do
    schedule
    |> Map.put("enabled", false)
    |> Map.put("status", "completed")
    |> Map.put("next_run_at", nil)
  end

  defp maybe_complete_one_shot(schedule), do: schedule

  defp maybe_attach_resource_availability(%{"kind" => "resource_wait"} = schedule, manifest) do
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

  defp maybe_attach_resource_availability(schedule, _manifest), do: {:ok, schedule}

  defp resource_wait_ready?(schedule) do
    case Manifest.load(Map.get(schedule, "manifest", %{})) do
      {:ok, manifest} -> Scheduler.availability(manifest)
      {:error, reason} -> {:error, availability_error(reason)}
    end
  end

  defp availability_error(%{} = availability), do: availability

  defp availability_error(reason) do
    %{
      "status" => "not_runnable",
      "reason" => reason_to_string(reason)
    }
  end

  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp mutate_schedule(schedule_id, update) do
    with_schedule_state_lock(schedule_id, fn lock ->
      mutate_schedule_with_lock(schedule_id, lock, update)
    end)
  end

  defp mutate_schedule_with_lock(schedule_id, lock, update) do
    with {:ok, current} <- RedisStore.fetch_schedule(schedule_id),
         {:ok, next_schedule} <- apply_schedule_update(update, current) do
      RedisStore.persist_schedule_fenced(
        schedule_id,
        next_schedule,
        lock.lease_name,
        lock.owner,
        lock.lease["epoch"]
      )
    end
  end

  defp apply_schedule_update(update, current) do
    case update.(current) do
      {:ok, next_schedule} when is_map(next_schedule) -> {:ok, next_schedule}
      {:error, _reason} = error -> error
      next_schedule when is_map(next_schedule) -> {:ok, next_schedule}
      other -> {:error, {:invalid_schedule_update, other}}
    end
  end

  defp delete_schedule_locked(schedule_id) do
    with_schedule_state_lock(schedule_id, fn lock ->
      RedisStore.delete_schedule_fenced(
        schedule_id,
        lock.lease_name,
        lock.owner,
        lock.lease["epoch"]
      )
    end)
  end

  defp with_schedule_state_lock(schedule_id, operation) do
    deadline = System.monotonic_time(:millisecond) + @state_lease_wait_ms
    with_schedule_state_lock(schedule_id, operation, deadline)
  end

  defp with_schedule_state_lock(schedule_id, operation, deadline) do
    case acquire_schedule_state_lock(schedule_id, deadline) do
      {:ok, lock} ->
        result =
          try do
            operation.(lock)
          after
            _ =
              RedisStore.release_fenced_lease(
                lock.lease_name,
                lock.owner,
                lock.lease["epoch"]
              )
          end

        if result == {:error, :not_owner} and before_deadline?(deadline) do
          with_schedule_state_lock(schedule_id, operation, deadline)
        else
          result
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp acquire_schedule_state_lock(schedule_id, deadline) do
    lease_name = "schedule:#{schedule_id}:state"
    owner = "#{Node.self()}:#{System.unique_integer([:positive, :monotonic])}"
    acquire_schedule_state_lock(schedule_id, lease_name, owner, deadline)
  end

  defp acquire_schedule_state_lock(schedule_id, lease_name, owner, deadline) do
    case RedisStore.acquire_fenced_lease(lease_name, owner, @state_lease_ttl_ms) do
      {:ok, lease} ->
        {:ok, %{lease_name: lease_name, owner: owner, lease: lease}}

      {:error, {:locked, _lease}} ->
        if before_deadline?(deadline) do
          Process.sleep(@state_lease_retry_ms)
          acquire_schedule_state_lock(schedule_id, lease_name, owner, deadline)
        else
          {:error, {:schedule_state_lock_timeout, schedule_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp before_deadline?(deadline), do: System.monotonic_time(:millisecond) < deadline

  defp log_schedule_update_failure(_schedule_id, {:ok, _schedule}), do: :ok
  defp log_schedule_update_failure(_schedule_id, :ok), do: :ok

  defp log_schedule_update_failure(schedule_id, {:error, reason}) do
    Logger.error("failed to update schedule #{schedule_id}: #{inspect(reason)}")
    :ok
  end

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

  defp increment_counter(schedule, key) do
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

  defp filter_schedules(schedules, opts) do
    Enum.filter(schedules, fn schedule ->
      Enum.all?(opts, fn
        {:kind, value} when is_binary(value) and value != "" -> schedule["kind"] == value
        {:status, value} when is_binary(value) and value != "" -> schedule["status"] == value
        {:enabled, value} when is_boolean(value) -> schedule["enabled"] == value
        _other -> true
      end)
    end)
  end

  defp reduce_results(results) do
    Enum.reduce(results, empty_result(), fn
      {:ok, result}, acc when is_map(result) -> merge_counts(acc, result)
      result, acc when is_map(result) -> merge_counts(acc, result)
      _other, acc -> acc
    end)
  end

  defp merge_counts(left, right) do
    Map.merge(left, right, fn
      :event, _left, right ->
        right

      _key, left_value, right_value when is_integer(left_value) and is_integer(right_value) ->
        left_value + right_value

      _key, _left_value, right_value ->
        right_value
    end)
  end

  defp empty_result do
    %{checked: 0, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 0, windows_closed: 0}
  end

  defp dispatch_token(schedule, instance) do
    :crypto.hash(
      :sha256,
      Jason.encode!(%{
        schedule_id: schedule["schedule_id"],
        scheduled_for: instance["scheduled_for"],
        reason: instance["reason"],
        event_id: get_in(instance, ["event", "event_id"])
      })
    )
    |> Base.url_encode64(padding: false)
  end

  defp generate_schedule_id do
    "sched_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp generate_dispatch_id do
    "dispatch_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp generate_event_id do
    "event_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp stringify(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify(value)}
    end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
