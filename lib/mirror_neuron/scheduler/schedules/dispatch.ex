defmodule MirrorNeuron.Scheduler.Schedules.Dispatch do
  @moduledoc "Claims each occurrence and launches its authorized run under fenced leases."

  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Scheduler.Schedules.Eligibility
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Scheduler.Schedules.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ScheduleOccurrence
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Scheduler.Schedules.State
  alias MirrorNeuron.Scheduler.Schedules.Values

  @lease_ttl_ms 30_000

  def dispatch_with_lease(schedule, trigger, instance) do
    if Eligibility.schedule_owner?(schedule) do
      do_dispatch_with_lease(schedule, trigger, instance)
    else
      %{checked: 1, dispatched: 0, skipped: 1, failed: 0, missed: 0, blocked: 0}
    end
  end

  defp do_dispatch_with_lease(schedule, trigger, instance) do
    lease_name =
      "schedule:#{schedule["schedule_id"]}:#{ScheduleOccurrence.token(schedule, instance)}"

    owner = "#{Node.self()}:#{System.unique_integer([:positive])}"

    case RedisStore.acquire_fenced_lease(lease_name, owner, @lease_ttl_ms) do
      {:ok, lease} ->
        try do
          case State.with_schedule_state_lock(schedule["schedule_id"], fn lock ->
                 with {:ok, current_schedule} <-
                        RedisStore.fetch_schedule(schedule["schedule_id"]) do
                   if Eligibility.eligible?(current_schedule, trigger, instance) do
                     dispatch_child(current_schedule, instance, lease, lock)
                   else
                     %{checked: 1, dispatched: 0, skipped: 1, failed: 0, missed: 0, blocked: 0}
                   end
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

  defp dispatch_child(schedule, instance, lease, state_lock) do
    dispatch_id =
      if Eligibility.service_schedule?(schedule),
        do: generate_dispatch_id(),
        else: ScheduleOccurrence.token(schedule, instance)

    metadata = schedule_dispatch_metadata(schedule, instance, dispatch_id, lease)

    start = fn run_id ->
      start_scheduled_run(schedule, Map.put(metadata, "reserved_run_id", run_id))
    end

    dispatched =
      if Eligibility.service_schedule?(schedule),
        do: start_scheduled_run(schedule, metadata),
        else: ScheduleOccurrence.run(schedule, metadata, state_lock, start)

    with {:ok, started} <- dispatched do
      run_id = started.run_id

      case Records.update_after_dispatch(
             schedule,
             dispatch_id,
             run_id,
             instance,
             metadata,
             started,
             state_lock
           ) do
        {:ok, _saved} ->
          %{checked: 1, dispatched: 1, skipped: 0, failed: 0, missed: 0, blocked: 0}

        {:error, reason} ->
          State.log_schedule_update_failure(schedule["schedule_id"], {:error, reason})
          %{checked: 1, dispatched: 0, skipped: 0, failed: 1, missed: 0, blocked: 0}
      end
    else
      {:error, {:service_schedule_blocked, reason}} ->
        State.log_schedule_update_failure(
          schedule["schedule_id"],
          Records.update_after_dispatch_blocked(
            schedule,
            dispatch_id,
            instance,
            reason,
            state_lock
          )
        )

        %{checked: 1, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 1}

      {:error, reason} ->
        State.log_schedule_update_failure(
          schedule["schedule_id"],
          Records.update_after_dispatch_failure(
            schedule,
            dispatch_id,
            instance,
            reason,
            state_lock
          )
        )

        %{checked: 1, dispatched: 0, skipped: 0, failed: 1, missed: 0, blocked: 0}
    end
  end

  defp start_scheduled_run(schedule, metadata) do
    epoch = schedule["authority_epoch"]

    if epoch == nil or MirrorNeuron.Runtime.NodeAdmission.authorized?(epoch) do
      start_authorized_scheduled_run(schedule, metadata)
    else
      {:error, "Scheduled start requires review because its authorization changed."}
    end
  end

  defp start_authorized_scheduled_run(%{"job_id" => job_id}, metadata)
       when is_binary(job_id) and job_id != "" do
    opts = [schedule_metadata: metadata, inputs: Map.get(metadata, "payload", %{})]
    StableJob.scheduled_transition(job_id, reserved_run_option(opts, :run_id, metadata))
  end

  defp start_authorized_scheduled_run(schedule, metadata) do
    with {:ok, bundle_or_manifest} <- load_dispatch_bundle(schedule, metadata) do
      case Runtime.start_job(
             dispatch_manifest(bundle_or_manifest),
             reserved_run_option(dispatch_opts(bundle_or_manifest), :job_id, metadata)
           ) do
        {:ok, run_id, pid} ->
          status =
            case RedisStore.fetch_job(run_id) do
              {:ok, run} -> run["status"] || "pending"
              _ -> "pending"
            end

          {:ok,
           %{
             action: if(status == "queued", do: "queued", else: "started"),
             run_id: run_id,
             status: status,
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

  defp reserved_run_option(opts, key, %{"reserved_run_id" => run_id}) when is_binary(run_id),
    do: Keyword.put(opts, key, run_id)

  defp reserved_run_option(opts, _key, _metadata), do: opts

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
      |> Values.stringify()
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

  defp generate_dispatch_id do
    "dispatch_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
