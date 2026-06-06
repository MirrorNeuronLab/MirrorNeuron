defmodule MirrorNeuron.Runtime.ScheduleDispatcher do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.SchedulePolicy

  @lease_ttl_ms 30_000
  @terminal_statuses ["completed", "failed", "cancelled"]

  def create_schedule(input, schedule_attrs \\ %{}, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         {:ok, schedule} <- normalize_schedule(bundle, schedule_attrs, opts),
         {:ok, schedule} <- maybe_attach_resource_availability(schedule, bundle.manifest) do
      schedule_id = Keyword.get(opts, :schedule_id) || generate_schedule_id()
      manifest_map = Manifest.to_map(bundle.manifest)
      bundle_ref = Runtime.bundle_ref(bundle.manifest, bundle)

      record =
        schedule
        |> Map.put("schedule_id", schedule_id)
        |> Map.put("manifest", manifest_map)
        |> Map.put("bundle_ref", bundle_ref)
        |> Map.put("source", stringify(Keyword.get(opts, :source, %{})))
        |> Map.put("dispatches", [])
        |> Map.put("active_job_ids", [])
        |> Map.put("counters", %{"dispatched" => 0, "missed" => 0, "failed" => 0})

      RedisStore.persist_schedule(schedule_id, record)
    end
  end

  def update_schedule(schedule_id, attrs, opts \\ []) do
    with {:ok, existing} <- RedisStore.fetch_schedule(schedule_id),
         {:ok, normalized} <-
           existing
           |> Map.merge(stringify(attrs || %{}))
           |> SchedulePolicy.normalize(Map.get(existing, "manifest", %{}), opts) do
      normalized
      |> Map.merge(
        Map.take(existing, [
          "schedule_id",
          "manifest",
          "bundle_ref",
          "source",
          "dispatches",
          "active_job_ids",
          "counters",
          "created_at"
        ])
      )
      |> then(&RedisStore.persist_schedule(schedule_id, &1))
    end
  end

  def pause_schedule(schedule_id, opts \\ []) do
    update_schedule_state(schedule_id, "paused", false, opts)
  end

  def resume_schedule(schedule_id, opts \\ []) do
    with {:ok, schedule} <- RedisStore.fetch_schedule(schedule_id),
         {:ok, normalized} <-
           SchedulePolicy.normalize(
             Map.put(schedule, "enabled", true),
             Map.get(schedule, "manifest", %{}),
             opts
           ) do
      RedisStore.persist_schedule(schedule_id, Map.merge(schedule, normalized))
    end
  end

  def delete_schedule(schedule_id, _opts \\ []), do: RedisStore.delete_schedule(schedule_id)

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

    with {:ok, schedule} <- RedisStore.fetch_schedule(schedule_id) do
      schedule
      |> Map.merge(%{
        "status" => status,
        "enabled" => enabled,
        "last_status_reason" => reason,
        "updated_at" => now
      })
      |> then(&RedisStore.persist_schedule(schedule_id, &1))
    end
  end

  defp process_due_schedule(schedule, now) do
    cond do
      schedule["kind"] == "resource_wait" ->
        process_resource_wait_schedule(schedule, now)

      SchedulePolicy.missed?(schedule, now) ->
        mark_missed(schedule, now)

      overlap_blocked?(schedule) ->
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
    if overlap_blocked?(schedule) do
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
      overlap_blocked?(schedule) ->
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
    lease_name = "schedule:#{schedule["schedule_id"]}:#{dispatch_token(schedule, instance)}"
    owner = "#{Node.self()}:#{System.unique_integer([:positive])}"

    case RedisStore.acquire_fenced_lease(lease_name, owner, @lease_ttl_ms) do
      {:ok, lease} ->
        try do
          dispatch_child(schedule, instance, lease)
        after
          _ = RedisStore.release_fenced_lease(lease_name, owner, lease["epoch"])
        end

      {:error, {:locked, _lease}} ->
        %{checked: 1, dispatched: 0, skipped: 1, failed: 0, missed: 0, blocked: 0}

      {:error, reason} ->
        Logger.warning("schedule lease failed: #{inspect(reason)}")
        %{checked: 1, dispatched: 0, skipped: 0, failed: 1, missed: 0, blocked: 0}
    end
  end

  defp dispatch_child(schedule, instance, lease) do
    dispatch_id = generate_dispatch_id()
    metadata = schedule_dispatch_metadata(schedule, instance, dispatch_id, lease)

    with {:ok, bundle_or_manifest} <- load_dispatch_bundle(schedule, metadata),
         {:ok, job_id, _pid} <-
           Runtime.start_job(
             dispatch_manifest(bundle_or_manifest),
             dispatch_opts(bundle_or_manifest)
           ) do
      update_after_dispatch(schedule, dispatch_id, job_id, instance, metadata)
      %{checked: 1, dispatched: 1, skipped: 0, failed: 0, missed: 0, blocked: 0}
    else
      {:error, reason} ->
        update_after_dispatch_failure(schedule, dispatch_id, instance, reason)
        %{checked: 1, dispatched: 0, skipped: 0, failed: 1, missed: 0, blocked: 0}
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

  defp update_after_dispatch(schedule, dispatch_id, job_id, instance, metadata) do
    now = Runtime.timestamp()
    window_end_at = window_end_at(schedule, now)
    current = current_schedule(schedule)

    dispatch =
      %{
        "dispatch_id" => dispatch_id,
        "job_id" => job_id,
        "status" => "submitted",
        "scheduled_for" => instance["scheduled_for"],
        "reason" => instance["reason"],
        "submitted_at" => now,
        "window_end_at" => window_end_at,
        "metadata" => metadata
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    current
    |> prepend_dispatch(dispatch)
    |> Map.update("active_job_ids", [job_id], &Enum.uniq([job_id | &1]))
    |> increment_counter("dispatched")
    |> maybe_complete_one_shot()
    |> then(&RedisStore.persist_schedule(schedule["schedule_id"], &1))
  end

  defp update_after_dispatch_failure(schedule, dispatch_id, instance, reason) do
    now = Runtime.timestamp()
    current = current_schedule(schedule)

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

    current
    |> prepend_dispatch(dispatch)
    |> increment_counter("failed")
    |> then(&RedisStore.persist_schedule(schedule["schedule_id"], &1))
  end

  defp advance_schedule(result, schedule, now) do
    if result.dispatched > 0 and schedule["kind"] == "periodic" do
      next_run_at = SchedulePolicy.next_run_at(schedule, DateTime.add(now, 60, :second))
      current = current_schedule(schedule)

      _ =
        RedisStore.persist_schedule(
          schedule["schedule_id"],
          Map.put(current, "next_run_at", next_run_at)
        )
    end

    result
  end

  defp mark_missed(schedule, now) do
    next_run_at = SchedulePolicy.next_run_at(schedule, now)

    _ =
      schedule
      |> Map.put("next_run_at", next_run_at)
      |> Map.put("last_missed_at", DateTime.to_iso8601(now))
      |> increment_counter("missed")
      |> then(&RedisStore.persist_schedule(schedule["schedule_id"], &1))

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 1, blocked: 0}
  end

  defp mark_blocked(schedule, reason) do
    _ =
      schedule
      |> Map.put("last_blocked_reason", reason)
      |> Map.put("updated_at", Runtime.timestamp())
      |> then(&RedisStore.persist_schedule(schedule["schedule_id"], &1))

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 1}
  end

  defp postpone_resource_wait(schedule, now, reason, availability \\ %{}) do
    next_run_at =
      now
      |> DateTime.add(Map.get(schedule, "retry_interval_ms", 30_000), :millisecond)
      |> DateTime.to_iso8601()

    _ =
      schedule
      |> Map.put("next_run_at", next_run_at)
      |> Map.put("last_blocked_reason", reason || "resources unavailable")
      |> Map.put("resource_availability", availability)
      |> Map.put("updated_at", Runtime.timestamp())
      |> increment_counter("blocked")
      |> then(&RedisStore.persist_schedule(schedule["schedule_id"], &1))

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 1}
  end

  defp process_due_windows(schedules, now) do
    schedules
    |> Enum.flat_map(&due_window_dispatches(&1, now))
    |> Enum.map(&close_window/1)
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
        get_in(schedule, ["window", "end_action"]) == "cancel"
    end)
    |> Enum.map(&{schedule, &1})
  end

  defp close_window({schedule, dispatch}) do
    job_id = dispatch["job_id"]
    _ = if is_binary(job_id), do: MirrorNeuron.cancel(job_id), else: :ok

    updated_dispatches =
      Enum.map(schedule["dispatches"] || [], fn item ->
        if item["dispatch_id"] == dispatch["dispatch_id"] do
          item
          |> Map.put("status", "window_closed")
          |> Map.put("closed_at", Runtime.timestamp())
        else
          item
        end
      end)

    _ =
      schedule
      |> Map.put("dispatches", updated_dispatches)
      |> Map.update("active_job_ids", [], &List.delete(&1, job_id))
      |> then(&RedisStore.persist_schedule(schedule["schedule_id"], &1))

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 0, windows_closed: 1}
  end

  defp overlap_blocked?(%{"prohibit_overlap" => true} = schedule) do
    schedule
    |> Map.get("active_job_ids", [])
    |> Enum.any?(fn job_id ->
      case RedisStore.fetch_job(job_id) do
        {:ok, %{"status" => status}} -> status not in @terminal_statuses
        _ -> false
      end
    end)
  end

  defp overlap_blocked?(_schedule), do: false

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

  defp current_schedule(schedule) do
    case RedisStore.fetch_schedule(schedule["schedule_id"]) do
      {:ok, current} -> current
      _ -> schedule
    end
  end

  defp increment_counter(schedule, key) do
    counters = Map.get(schedule, "counters", %{})
    Map.put(schedule, "counters", Map.update(counters, key, 1, &((&1 || 0) + 1)))
  end

  defp prepend_dispatch(schedule, dispatch) do
    Map.update(schedule, "dispatches", [dispatch], fn dispatches ->
      [dispatch | dispatches] |> Enum.take(50)
    end)
  end

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
