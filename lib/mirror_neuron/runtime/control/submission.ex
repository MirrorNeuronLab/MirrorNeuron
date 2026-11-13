defmodule MirrorNeuron.Runtime.Submission do
  @moduledoc "Validates submissions, reserves admission and starts admitted run owners."

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.ContextEnginePreflight
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.InitialRecords
  alias MirrorNeuron.Runtime.JobRunner
  alias MirrorNeuron.Runtime.NodeAdmission
  alias MirrorNeuron.Runtime.PlacementFailure
  alias MirrorNeuron.Runtime.ReliabilityStrategy
  alias MirrorNeuron.Scheduler

  def start_job(manifest, opts \\ [])

  def start_job(%MirrorNeuron.Manifest{} = manifest, opts) do
    bundle = Keyword.get(opts, :job_bundle)

    with :ok <- validate_submission_identifiers(manifest, opts),
         {:ok, job_id} <- submission_job_id(manifest, opts) do
      service_preflight =
        MirrorNeuron.ServicePreflight.run(bundle || %MirrorNeuron.JobBundle{manifest: manifest})

      with :ok <- service_preflight,
           :ok <-
             ContextEnginePreflight.ensure_available(
               Map.get(manifest, :required_context_engine, false)
             ) do
        start_job_after_preflight(job_id, manifest, opts, bundle)
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def start_job(_manifest, _opts), do: {:error, "manifest must be a normalized workflow object"}

  defp start_job_after_preflight(job_id, manifest, opts, bundle) do
    manifest = NodeAdmission.pin(manifest)
    manifest_ref = bundle_ref(manifest, bundle)
    reliability = ReliabilityStrategy.resolve(manifest, manifest_ref: manifest_ref)

    :ok =
      MirrorNeuron.Artifacts.Registry.register_manifest_refs(
        MirrorNeuron.Manifest.to_map(manifest)
      )

    with :ok <- NodeAdmission.ensure_supported() do
      accept_job_on_node(job_id, manifest, opts, manifest_ref, reliability)
    end
  end

  defp accept_job_on_node(job_id, manifest, opts, manifest_ref, reliability) do
    policy =
      Keyword.get(
        opts,
        :admission_policy,
        if(Keyword.has_key?(opts, :schedule_metadata), do: "enqueue_if_busy", else: "start_now")
      )

    with {:ok, scheduler_plan} <-
           Scheduler.plan(manifest, Keyword.merge(opts, jobs: [], exclusive_run: true)),
         {:ok, admission} <-
           MirrorNeuron.Runtime.StableJob.with_start_gate(NodeAdmission.gate_id(job_id), fn ->
             job = %{
               "job_id" => job_id,
               "stable_job_id" => Keyword.get(opts, :stable_job_id),
               "job_name" => manifest.job_name,
               "manifest" => MirrorNeuron.Manifest.to_map(manifest),
               "submitted_at" => Runtime.timestamp()
             }

             with {:ok, admission} <- NodeAdmission.reserve(job, policy) do
               admission = Map.put(admission, "authority_epoch", NodeAdmission.authority_epoch())

               persisted =
                 InitialRecords.persist_initial_job(
                   job_id,
                   manifest,
                   manifest_ref,
                   reliability,
                   scheduler_plan,
                   opts
                   |> Keyword.put(:admission_status, "queued")
                   |> Keyword.put(:admission, admission)
                 )

               case persisted do
                 :ok ->
                   {:ok, admission}

                 error ->
                   if admission["state"] == "preparing",
                     do: NodeAdmission.retire(job_id),
                     else: NodeAdmission.cancel_uncommitted(job_id)

                   error
               end
             end
           end) do
      NodeAdmission.wake()

      if admission["state"] == "queued" do
        {:ok, job_id, nil}
      else
        case NodeAdmission.dispatch(%{"run_id" => job_id}) do
          {:error, {:admission_wait, _}} -> {:ok, job_id, nil}
          result -> result
        end
      end
    else
      {:error, reason} when is_binary(reason) ->
        PlacementFailure.maybe_pause_placement_failure(
          job_id,
          manifest,
          manifest_ref,
          reliability,
          opts,
          reason
        )

      error ->
        error
    end
  end

  @doc false
  def start_admitted_job(job) do
    # JobCoordinator owns the bounded staged-input wait before entrypoint
    # delivery. Admission must not reject a normal replication delay here.
    with {:ok, manifest} <- MirrorNeuron.Manifest.load(job["manifest"]),
         {:ok, bundle} <- admitted_bundle(job, manifest),
         :ok <- MirrorNeuron.BlueprintValidation.run_input_validation(bundle),
         :ok <- MirrorNeuron.ServicePreflight.run(bundle),
         :ok <-
           ContextEnginePreflight.ensure_available(
             Map.get(manifest, :required_context_engine, false)
           ),
         {:ok, admission} <- NodeAdmission.receipt(job["job_id"]),
         true <- admission["state"] == "preparing" do
      opts = [
        job_bundle: bundle,
        job_id: job["job_id"],
        run_id: job["run_id"] || job["job_id"],
        stable_job_id: job["stable_job_id"],
        job_data_dir: job["job_data_dir"],
        job_data_access: job["job_data_access"],
        data_generation: job["data_generation"],
        admission: admission
      ]

      manifest = NodeAdmission.pin(manifest, admission["generation"], admission["allocation"])
      opts = Keyword.put(opts, :job_bundle, %{bundle | manifest: manifest})
      reliability = ReliabilityStrategy.resolve(manifest, manifest_ref: job["manifest_ref"])

      case Scheduler.plan(manifest,
             jobs: [],
             exclusive_run: true,
             run_allocation: admission["allocation"]
           ) do
        {:ok, plan} ->
          start_planned_job(
            job["job_id"],
            manifest,
            opts,
            nil,
            job["manifest_ref"],
            reliability,
            plan
          )

        {:error, reason} ->
          {:error, {:admission_wait, reason}}
      end
    else
      false -> {:error, :node_not_reserved}
      error -> error
    end
  end

  defp admitted_bundle(job, manifest) do
    reference = job["manifest_ref"] || %{}

    result =
      cond do
        is_binary(reference["bundle_fingerprint"]) ->
          Archive.load(reference["bundle_fingerprint"])

        is_binary(reference["job_path"]) ->
          MirrorNeuron.JobBundle.load_filesystem_path(reference["job_path"])

        true ->
          MirrorNeuron.JobBundle.load(manifest)
      end

    case result do
      {:ok, bundle} -> {:ok, %{bundle | manifest: manifest}}
      error -> error
    end
  end

  defp start_planned_job(
         job_id,
         manifest,
         opts,
         _bundle,
         manifest_ref,
         reliability,
         scheduler_plan
       ) do
    with opts <-
           opts
           |> Keyword.put(:bundle_ref, manifest_ref)
           |> Keyword.put(:reliability, reliability)
           |> Keyword.put(:scheduler_plan, scheduler_plan)
           |> Keyword.put(:requested_recovery_policy, reliability["requested_recovery_policy"])
           |> Keyword.put(:recovery_policy, reliability["effective_recovery_policy"])
           |> Keyword.put_new(:preferred_start_node, to_string(Node.self())),
         :ok <-
           InitialRecords.persist_initial_job(
             job_id,
             manifest,
             manifest_ref,
             reliability,
             scheduler_plan,
             opts
           ) do
      InitialRecords.publish_reliability_events(job_id, reliability)

      spec = {JobRunner, {job_id, manifest, opts}}

      case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
        {:ok, pid} ->
          {:ok, job_id, pid}

        {:error, {:already_started, pid}} ->
          {:ok, job_id, pid}

        {:error, reason} ->
          InitialRecords.persist_startup_failure(
            job_id,
            manifest,
            manifest_ref,
            reliability,
            scheduler_plan,
            reason
          )

          {:error, "failed to start job runner: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def generate_job_id(graph_id), do: JobId.generate(graph_id)

  defp validate_submission_identifiers(manifest, opts) do
    with :ok <- validate_identifier("graph_id", manifest.graph_id),
         :ok <- validate_identifier("job_name", manifest.job_name),
         :ok <- validate_optional_identifier("job_id", Keyword.get(opts, :job_id)) do
      :ok
    end
  end

  defp submission_job_id(manifest, opts) do
    case Keyword.get(opts, :job_id) do
      nil -> {:ok, generate_job_id(manifest.graph_id)}
      job_id -> {:ok, job_id}
    end
  end

  defp validate_optional_identifier(_field, nil), do: :ok

  defp validate_optional_identifier(field, value), do: validate_identifier(field, value)

  defp validate_identifier(field, value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, "#{field} must be a non-empty string"}
    else
      :ok
    end
  end

  defp validate_identifier(field, _value), do: {:error, "#{field} must be a non-empty string"}

  @doc false
  def bundle_ref(manifest, bundle) do
    base_ref = %{
      "graph_id" => manifest.graph_id,
      "manifest_version" => manifest.manifest_version,
      "manifest_path" => bundle && bundle.manifest_path,
      "job_path" => bundle && bundle.root_path
    }

    case Archive.store(bundle) do
      {:ok, archive_ref} ->
        base_ref
        |> Map.put("bundle_fingerprint", archive_ref.fingerprint)
        |> Map.put("bundle_storage", archive_ref.storage)
        |> Map.put("bundle_bytes", archive_ref.total_bytes)
        |> Map.put("cache_path", Archive.cache_path(archive_ref.fingerprint))

      {:error, _reason} ->
        base_ref
    end
  end
end
