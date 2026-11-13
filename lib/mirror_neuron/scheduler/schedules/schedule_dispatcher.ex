defmodule MirrorNeuron.Runtime.ScheduleDispatcher do
  @moduledoc "Schedule CRUD and trigger processing; delegates dispatch, state fencing and windows."

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Scheduler.Schedules.Dispatch
  alias MirrorNeuron.Scheduler.Schedules.Eligibility
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Scheduler.Schedules.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Scheduler.Schedules.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.SchedulePolicy
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Scheduler.Schedules.State
  alias MirrorNeuron.Scheduler.Schedules.Values
  alias MirrorNeuron.Scheduler.Schedules.Windows

  @doc "Creates a schedule whose target is a stable job."
  def create_job_schedule(job_id, schedule_attrs \\ %{}, opts \\ []) do
    with {:ok, definition} <- StableJob.get(job_id),
         :ok <- ensure_stable_job_active(definition),
         {:ok, manifest} <- Manifest.load(definition["manifest"]),
         {:ok, bundle} <- load_definition_bundle(definition, manifest),
         {:ok, schedule} <- normalize_schedule(bundle, schedule_attrs, opts),
         {:ok, schedule} <- Eligibility.maybe_attach_resource_availability(schedule, manifest) do
      schedule_id = Keyword.get(opts, :schedule_id) || generate_schedule_id()

      record =
        schedule
        |> Map.put("schedule_id", schedule_id)
        |> Map.put("job_id", job_id)
        |> Map.put("owner_node", definition["owner_node"])
        |> Map.put("authority_epoch", MirrorNeuron.Runtime.NodeAdmission.authority_epoch())
        |> Map.put("manifest", definition["manifest"])
        |> Map.put("bundle_ref", definition["bundle_ref"])
        |> Map.put("source", Values.stringify(Keyword.get(opts, :source, %{})))
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
    case RedisStore.fetch_schedule(schedule_id) do
      {:ok, %{"target_run_id" => run_id}} ->
        MirrorNeuron.Runtime.NodeAdmission.defer(
          run_id,
          attrs["run_at"] || attrs[:run_at],
          Keyword.get(opts, :expected_revision, 0)
        )

      _ ->
        update_ordinary_schedule(schedule_id, attrs, opts)
    end
  end

  defp update_ordinary_schedule(schedule_id, attrs, opts) do
    State.mutate_schedule(schedule_id, fn existing ->
      with :ok <- State.check_expected_revision(existing, opts),
           {:ok, normalized} <-
             existing
             |> Map.merge(Values.stringify(attrs || %{}))
             |> SchedulePolicy.normalize(Map.get(existing, "manifest", %{}), opts) do
        {:ok,
         Map.merge(
           normalized,
           Map.take(existing, [
             "schedule_id",
             "owner_node",
             "authority_epoch",
             "job_id",
             "manifest",
             "bundle_ref",
             "source",
             "dispatches",
             "active_run_ids",
             "counters",
             "created_at",
             "revision"
           ])
         )}
      end
    end)
  end

  def pause_schedule(schedule_id, opts \\ []) do
    update_schedule_state(schedule_id, "paused", false, opts)
  end

  def resume_schedule(schedule_id, opts \\ []) do
    State.mutate_schedule(schedule_id, fn schedule ->
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

  def delete_schedule(schedule_id, opts \\ []) do
    case RedisStore.fetch_schedule(schedule_id) do
      {:ok, %{"target_run_id" => run_id}} ->
        MirrorNeuron.Runtime.NodeAdmission.cancel(
          run_id,
          Keyword.get(opts, :expected_revision, 0)
        )

      _ ->
        State.delete_schedule_locked(schedule_id, opts)
    end
  end

  def get_schedule(schedule_id), do: RedisStore.fetch_schedule(schedule_id)

  def list_schedules(opts \\ []) do
    with {:ok, schedules} <- RedisStore.list_schedules() do
      {:ok, filter_schedules(schedules, opts)}
    end
  end

  def dispatch_schedule(schedule_id, payload \\ %{}, opts \\ []) do
    with {:ok, schedule} <- RedisStore.fetch_schedule(schedule_id) do
      Dispatch.dispatch_with_lease(schedule, :manual, %{
        "scheduled_for" => Runtime.timestamp(),
        "reason" => Keyword.get(opts, :reason, "manual"),
        "payload" => Values.stringify(payload || %{})
      })
    end
  end

  def process_due_schedules(now \\ SchedulePolicy.now()) do
    now_iso = DateTime.to_iso8601(now)

    with {:ok, due} <- RedisStore.list_due_schedules(now_iso),
         {:ok, all} <- RedisStore.list_schedules() do
      window_result = Windows.process_due_windows(all, now)

      due_result =
        due
        |> Enum.map(&process_due_schedule(&1, now))
        |> Results.reduce_results()

      {:ok, Results.merge_counts(due_result, window_result)}
    end
  end

  def emit_event(event_type, payload \\ %{}, opts \\ []) do
    event_id = Keyword.get(opts, :event_id) || generate_event_id()

    event = %{
      "event_id" => event_id,
      "event_type" => to_string(event_type),
      "source" => Keyword.get(opts, :source, "runtime"),
      "payload" => Values.stringify(payload || %{}),
      "created_at" => Runtime.timestamp()
    }

    with {:ok, persisted} <- RedisStore.append_trigger_event(event_id, event),
         {:ok, schedules} <- RedisStore.list_schedules() do
      matches =
        schedules
        |> Enum.filter(&SchedulePolicy.event_matches?(&1, persisted))
        |> Enum.map(&dispatch_event_schedule(&1, persisted))
        |> Results.reduce_results()

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
      if map_size(Values.stringify(attrs || %{})) == 0 do
        manifest_schedule
      else
        attrs
      end

    SchedulePolicy.normalize(attrs, bundle.manifest, opts)
  end

  defp update_schedule_state(schedule_id, status, enabled, opts) do
    reason = Keyword.get(opts, :reason, "")
    now = Runtime.timestamp()

    State.mutate_schedule(schedule_id, fn schedule ->
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
      is_binary(schedule["target_run_id"]) ->
        if schedule["owner_node"] == MirrorNeuron.Runtime.NodeAdmission.node_name(),
          do: MirrorNeuron.Runtime.NodeAdmission.wake()

        %{checked: 1, dispatched: 0, skipped: 1, failed: 0, missed: 0, blocked: 0}

      schedule["kind"] == "resource_wait" ->
        process_resource_wait_schedule(schedule, now)

      SchedulePolicy.missed?(schedule, now) ->
        mark_missed(schedule, now)

      Eligibility.overlap_blocked?(schedule) and not Eligibility.service_schedule?(schedule) ->
        mark_blocked(schedule, "overlap")

      true ->
        schedule
        |> SchedulePolicy.due_instances(now)
        |> Enum.map(&Dispatch.dispatch_with_lease(schedule, {:due, now}, &1))
        |> Results.reduce_results()
        |> advance_schedule(schedule, now)
    end
  end

  defp dispatch_event_schedule(schedule, event) do
    if Eligibility.overlap_blocked?(schedule) and not Eligibility.service_schedule?(schedule) do
      mark_blocked(schedule, "overlap")
    else
      Dispatch.dispatch_with_lease(schedule, {:event, event}, %{
        "scheduled_for" => event["created_at"],
        "reason" => "event",
        "event" => event
      })
    end
  end

  defp process_resource_wait_schedule(schedule, now) do
    cond do
      Eligibility.overlap_blocked?(schedule) and not Eligibility.service_schedule?(schedule) ->
        postpone_resource_wait(schedule, now, "overlap")

      true ->
        case Eligibility.resource_wait_ready?(schedule) do
          {:ok, availability} ->
            schedule
            |> SchedulePolicy.due_instances(now)
            |> Enum.map(
              &Dispatch.dispatch_with_lease(
                Map.put(schedule, "resource_availability", availability),
                {:due, now},
                &1
              )
            )
            |> Results.reduce_results()

          {:blocked, availability} ->
            postpone_resource_wait(schedule, now, Map.get(availability, "reason"), availability)

          {:error, availability} ->
            availability = Eligibility.availability_error(availability)
            postpone_resource_wait(schedule, now, Map.get(availability, "reason"), availability)
        end
    end
  end

  defp load_definition_bundle(definition, manifest) do
    fingerprint = get_in(definition, ["bundle_ref", "bundle_fingerprint"])

    case Archive.load(fingerprint) do
      {:ok, %JobBundle{} = bundle} -> {:ok, bundle}
      {:error, _reason} -> {:ok, %JobBundle{manifest: manifest}}
    end
  end

  defp advance_schedule(result, schedule, now) do
    occurrence_consumed =
      result.dispatched > 0 or (Eligibility.service_schedule?(schedule) and result.blocked > 0)

    if occurrence_consumed and schedule["kind"] == "periodic" do
      next_run_at = SchedulePolicy.next_run_at(schedule, DateTime.add(now, 60, :second))

      case State.mutate_observed_schedule(schedule, &Map.put(&1, "next_run_at", next_run_at)) do
        {:ok, _saved} ->
          result

        {:error, reason} ->
          State.log_schedule_update_failure(schedule["schedule_id"], {:error, reason})
          Map.update!(result, :failed, &(&1 + 1))
      end
    else
      result
    end
  end

  defp mark_missed(schedule, now) do
    next_run_at = SchedulePolicy.next_run_at(schedule, now)

    State.log_schedule_update_failure(
      schedule["schedule_id"],
      State.mutate_observed_schedule(schedule, fn current ->
        current
        |> Map.put("next_run_at", next_run_at)
        |> Map.put("last_missed_at", DateTime.to_iso8601(now))
        |> Records.increment_counter("missed")
      end)
    )

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 1, blocked: 0}
  end

  defp mark_blocked(schedule, reason) do
    State.log_schedule_update_failure(
      schedule["schedule_id"],
      State.mutate_observed_schedule(schedule, fn current ->
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

    State.log_schedule_update_failure(
      schedule["schedule_id"],
      State.mutate_observed_schedule(schedule, fn current ->
        current
        |> Map.put("next_run_at", next_run_at)
        |> Map.put("last_blocked_reason", reason || "resources unavailable")
        |> Map.put("resource_availability", availability)
        |> Map.put("updated_at", Runtime.timestamp())
        |> Records.increment_counter("blocked")
      end)
    )

    %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 1}
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

  defp generate_schedule_id do
    "sched_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp generate_event_id do
    "event_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
