defmodule MirrorNeuron.Runtime.StableJob.Runs do
  @moduledoc "Starts one attached service run or independent batch runs and reconciles start receipts."

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Runtime.StableJob.DataAccess
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.JobData
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Runtime.StableJob.Queries
  alias MirrorNeuron.Runtime.StableJob.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob.RunCleanup
  alias MirrorNeuron.Runtime.StableJob.RunManifest
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.StableJob.StartGate

  def start_run(job_id, opts \\ []) do
    case start_run_result(job_id, opts) do
      {:ok, result} -> {:ok, result.run_id, result.pid}
      {:error, _reason} = error -> error
    end
  end

  def start_run_result(job_id, opts \\ []) do
    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id),
           :ok <- Records.ensure_active(definition),
           :ok <- Records.ensure_owner_node(definition) do
        do_start_run_result(definition, opts)
      end
    end)
  end

  def delete_run(run_id, opts \\ []) do
    if Keyword.get(opts, :confirmed, false) do
      with {:ok, run} <- RedisStore.fetch_job(run_id),
           stable_job_id <-
             run["stable_job_id"] || get_in(run, ["manifest", "metadata", "job_id"]),
           {:ok, _cleanup} <- RunCleanup.cleanup_run(run_id),
           :ok <- detach_run(stable_job_id, run_id) do
        :ok
      end
    else
      {:error, :confirmation_required}
    end
  end

  defp attach_run(definition, run_id) do
    updated =
      definition
      |> Map.update("run_ids", [run_id], &Enum.uniq(&1 ++ [run_id]))
      |> Map.put("latest_run_id", run_id)
      |> Records.increment_revision()

    RedisStore.persist_job_definition(definition["job_id"], updated)
  end

  defp ensure_run_id_available(run_id) do
    case RedisStore.execution_exists?(run_id) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :run_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  def do_start_run_result(definition, opts) do
    replace_existing = Keyword.get(opts, :replace_existing_run, false)
    service = RunCleanup.service_definition?(definition)
    existing_run_ids = definition |> Map.get("run_ids", []) |> Enum.uniq()
    requested_run_id = Keyword.get(opts, :run_id)

    with :ok <- ensure_replacement_scope(service, replace_existing),
         {:replay, replay} <-
           replacement_replay(definition, requested_run_id, replace_existing) do
      {:ok, replay}
    else
      :continue ->
        do_start_new_run(
          definition,
          opts,
          service,
          replace_existing,
          existing_run_ids,
          requested_run_id
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp do_start_new_run(
         definition,
         opts,
         service,
         replace_existing,
         existing_run_ids,
         requested_run_id
       ) do
    job_id = definition["job_id"]
    access = DataAccess.requested_job_data_access(definition, opts)

    with :ok <- ensure_service_start_allowed(service, replace_existing, existing_run_ids),
         :ok <- ensure_replacement_run_id(requested_run_id, replace_existing, existing_run_ids),
         :ok <- maybe_ensure_job_data_access(definition, access, service and replace_existing),
         {:ok, %JobBundle{} = bundle} <- load_bundle(definition),
         run_id <- requested_run_id || JobId.generate_run(job_id),
         :ok <- JobData.validate_id(run_id),
         :ok <- ensure_fresh_replacement_run_id(run_id, existing_run_ids, replace_existing),
         :ok <- ensure_run_id_available(run_id),
         {:ok, data_dir} <- JobData.initialize(job_id),
         {:ok, manifest} <-
           RunManifest.prepare_run_manifest(
             bundle.manifest,
             definition,
             run_id,
             data_dir,
             access,
             opts
           ),
         run_bundle <- %JobBundle{bundle | manifest: manifest},
         :ok <- MirrorNeuron.BlueprintValidation.run_input_validation(run_bundle),
         {:ok, definition, replacement} <-
           maybe_replace_service_runs(definition, service and replace_existing),
         {:ok, attached_definition} <- attach_run(definition, run_id),
         result <-
           Runtime.start_job(manifest,
             job_id: run_id,
             job_bundle: run_bundle,
             stable_job_id: job_id,
             run_id: run_id,
             job_data_dir: data_dir,
             job_data_access: access,
             data_generation: definition["data_generation"],
             admission_policy:
               Keyword.get(
                 opts,
                 :admission_policy,
                 if(Keyword.has_key?(opts, :schedule_metadata),
                   do: "enqueue_if_busy",
                   else: "start_now"
                 )
               )
           ) do
      finish_started_run(result, attached_definition, run_id, replacement)
    end
  end

  defp finish_started_run({:ok, run_id, pid}, definition, run_id, replacement) do
    run =
      case RedisStore.fetch_job(run_id) do
        {:ok, value} -> value
        _ -> %{}
      end

    queued = run["status"] == "queued"

    admission =
      case MirrorNeuron.Runtime.NodeAdmission.receipt(run_id) do
        {:ok, value} -> value
        _ -> run["admission"]
      end

    {:ok,
     replacement
     |> Map.merge(%{
       action:
         if(queued,
           do: "queued",
           else: if(replacement.replaced_run_ids == [], do: "started", else: "replaced")
         ),
       job_id: definition["job_id"],
       run_id: run_id,
       status: if(queued, do: "queued", else: "pending"),
       admission: admission,
       message: admission && admission["message"],
       pid: pid
     })}
  end

  defp finish_started_run({:error, reason}, definition, run_id, _replacement) do
    _ = maybe_detach_unpersisted_run(definition, run_id)
    {:error, reason}
  end

  defp finish_started_run(other, _definition, _run_id, _replacement), do: other

  defp maybe_detach_unpersisted_run(definition, run_id) do
    case RedisStore.execution_exists?(run_id) do
      {:ok, true} -> :ok
      _missing -> detach_attached_run(definition, run_id)
    end
  end

  defp detach_attached_run(definition, run_id) do
    remaining = List.delete(Map.get(definition, "run_ids", []), run_id)

    updated =
      definition
      |> Map.put("run_ids", remaining)
      |> Map.put("latest_run_id", List.last(remaining))
      |> Records.increment_revision()

    RedisStore.persist_job_definition(definition["job_id"], updated)
  end

  defp replacement_replay(definition, run_id, true)
       when is_binary(run_id) and run_id != "" do
    existing_run_ids = definition |> Map.get("run_ids", []) |> Enum.uniq()

    if existing_run_ids == [run_id] do
      case RedisStore.fetch_job(run_id) do
        {:ok, run} ->
          {:replay,
           %{
             action: "already_running",
             job_id: definition["job_id"],
             run_id: run_id,
             status: run["status"] || "unknown",
             pid: nil,
             replaced_run_ids: [],
             cleanup_deferred: false,
             cleanup_pending_nodes: []
           }}

        _missing ->
          :continue
      end
    else
      :continue
    end
  end

  defp replacement_replay(_definition, _run_id, _replace_existing), do: :continue

  defp ensure_replacement_scope(true, _replace_existing), do: :ok

  defp ensure_replacement_scope(false, false), do: :ok

  defp ensure_replacement_scope(false, true), do: {:error, :replacement_requires_service_job}

  defp ensure_service_start_allowed(true, false, run_ids) when run_ids != [],
    do: {:error, {:service_run_exists, run_ids}}

  defp ensure_service_start_allowed(_service, _replace_existing, _run_ids), do: :ok

  defp ensure_replacement_run_id(nil, true, _run_ids),
    do: {:error, :replacement_run_id_required}

  defp ensure_replacement_run_id("", true, _run_ids), do: {:error, :replacement_run_id_required}

  defp ensure_replacement_run_id(_run_id, _replace_existing, _run_ids), do: :ok

  defp ensure_fresh_replacement_run_id(run_id, existing_run_ids, true) do
    if run_id in existing_run_ids,
      do: {:error, :replacement_run_id_must_be_fresh},
      else: :ok
  end

  defp ensure_fresh_replacement_run_id(_run_id, _existing_run_ids, false), do: :ok

  defp maybe_ensure_job_data_access(_definition, _access, true), do: :ok

  defp maybe_ensure_job_data_access(definition, access, false),
    do: DataAccess.ensure_job_data_access(definition, access)

  defp maybe_replace_service_runs(definition, true), do: RunCleanup.clear_service_runs(definition)

  defp maybe_replace_service_runs(definition, false),
    do: {:ok, definition, RunCleanup.empty_replacement()}

  def load_bundle(definition) do
    fingerprint = get_in(definition, ["bundle_ref", "bundle_fingerprint"])

    case Archive.load(fingerprint) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, _reason} -> JobBundle.load(definition["manifest"])
    end
  end

  defp detach_run(nil, _run_id), do: :ok

  defp detach_run(job_id, run_id) do
    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id) do
        remaining = List.delete(Map.get(definition, "run_ids", []), run_id)

        updated =
          definition
          |> Map.put("run_ids", remaining)
          |> Map.put("latest_run_id", List.last(remaining))

        case RedisStore.persist_job_definition(job_id, updated) do
          {:ok, _definition} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end
end
