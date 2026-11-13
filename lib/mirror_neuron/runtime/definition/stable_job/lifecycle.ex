defmodule MirrorNeuron.Runtime.StableJob.Lifecycle do
  @moduledoc "Revision-checked definition updates, replacement, archival, deletion and data reset."

  require Logger

  alias MirrorNeuron.Runtime.StableJob.DataAccess
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.JobData
  alias MirrorNeuron.Runtime.JobResponse
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.StableJob.Queries
  alias MirrorNeuron.Runtime.StableJob.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob.RunCleanup
  alias MirrorNeuron.Runtime.RunnerResources
  alias MirrorNeuron.Runtime.StableJob.Runs
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.StableJob.Schedules
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Runtime.StableJob.StartGate
  alias MirrorNeuron.Runtime.StableJob.Storage
  alias MirrorNeuron.Runtime.StableJob.Values

  def update(job_id, attrs, opts \\ [])

  def update(job_id, attrs, opts) when is_map(attrs) do
    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id),
           :ok <- Records.ensure_mutable(definition),
           :ok <- Records.ensure_revision(definition, Keyword.get(opts, :expected_revision)),
           {:ok, normalized_attrs} <- normalize_update(definition, Values.stringify(attrs)),
           {:ok, updated} <-
             MirrorNeuron.Runtime.StableJobUpdate.apply(definition, normalized_attrs) do
        updated =
          updated
          |> Records.increment_revision()
          |> Map.put("updated_at", Runtime.timestamp())

        Records.persist_and_reconcile(job_id, updated)
      end
    end)
  end

  def update(_job_id, _attrs, _opts), do: {:error, :invalid_job_update}

  def replace_bundle(job_id, input, attrs \\ %{}, opts \\ [])

  def replace_bundle(job_id, input, attrs, opts) when is_map(attrs) do
    allowed = ~w(resolved_configuration schedules storage job_name)

    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id),
           :ok <- Records.ensure_revision(definition, Keyword.get(opts, :expected_revision)),
           :ok <- Records.ensure_active(definition),
           :ok <- Records.ensure_owner_node(definition),
           {:ok, bundle} <- JobBundle.load(input),
           :ok <- ensure_same_bundle_identity(definition, bundle),
           {:ok, normalized_attrs} <- normalize_update(definition, Values.stringify(attrs)),
           {:ok, definition, replacement} <-
             RunCleanup.prepare_bundle_replacement(definition, bundle, opts) do
        updated =
          definition
          |> Map.merge(Map.take(normalized_attrs, allowed))
          |> Map.merge(%{
            "blueprint_id" => blueprint_id(bundle.manifest),
            "graph_id" => bundle.manifest.graph_id,
            "job_name" => bundle.manifest.job_name,
            "type" => bundle.manifest.type,
            "manifest" => Manifest.to_map(bundle.manifest),
            "bundle_ref" => Runtime.bundle_ref(bundle.manifest, bundle),
            "updated_at" => Runtime.timestamp(),
            "revision" => (definition["revision"] || 0) + 1
          })

        case RedisStore.persist_job_definition(job_id, updated) do
          {:ok, saved} ->
            _ = JobResponse.definition_changed(saved)

            cleanup_errors =
              case RunnerResources.cleanup_retired_native_resources(definition, saved) do
                :ok -> []
                {:error, failures} -> failures
              end

            {:ok,
             saved
             |> Map.merge(replacement)
             |> Map.put(
               "retired_definition_resources",
               definition_resource_descriptor(definition)
             )
             |> maybe_put_resource_cleanup_errors(cleanup_errors)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end

  def replace_bundle(_job_id, _input, _attrs, _opts), do: {:error, :invalid_job_update}

  def archive(job_id, opts \\ []) do
    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id),
           :ok <- Records.ensure_mutable(definition),
           :ok <- Records.ensure_revision(definition, Keyword.get(opts, :expected_revision)) do
        with :ok <- DataAccess.ensure_no_active_runs(definition),
             :ok <- Schedules.pause_job_schedules(job_id),
             :ok <- JobResponse.stop(definition, force: true),
             {:ok, runs} <- Queries.list_runs(job_id),
             :ok <- MirrorNeuron.Runtime.JobCleanup.retire_terminal_runs(runs),
             :ok <- cleanup_definition_native_resources(job_id, definition) do
          # A repeated archive also reconciles resources left by an interrupted
          # cleanup. Preserve history and acknowledge only the owner's receipt.
          if definition["status"] == "archived" do
            {:ok, definition}
          else
            RedisStore.persist_job_definition(
              job_id,
              definition |> Map.put("status", "archived") |> Records.increment_revision()
            )
          end
        end
      end
    end)
  end

  def reset_data(job_id) do
    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id),
           :ok <- Records.ensure_mutable(definition),
           :ok <- DataAccess.ensure_no_active_runs(definition),
           :ok <- JobResponse.stop(definition),
           {:ok, bundle} <- Runs.load_bundle(definition),
           {:ok, seeds} <- Storage.seed_paths(bundle, definition["storage"] || %{}),
           {:ok, data_dir} <- JobData.reset(job_id, seeds) do
        updated =
          definition
          |> Map.update("data_generation", 2, &(&1 + 1))
          |> Map.put("data_dir", data_dir)

        with {:ok, saved} <- Records.persist_and_reconcile(job_id, updated),
             {:ok, runs} <- Queries.list_runs(job_id) do
          Enum.reduce_while(runs, {:ok, saved}, fn run, result ->
            case RedisStore.discard_run_checkpoint(run["run_id"]) do
              :ok -> {:cont, result}
              error -> {:halt, error}
            end
          end)
        end
      end
    end)
  end

  def delete(job_id, opts \\ []) do
    if Keyword.get(opts, :confirmed, false) do
      StartGate.with_start_gate(job_id, fn ->
        with {:ok, definition} <- Queries.get(job_id),
             :ok <- Records.ensure_mutable(definition),
             :ok <- Records.ensure_revision(definition, Keyword.get(opts, :expected_revision)),
             :ok <-
               delete_step(job_id, :response_service, JobResponse.stop(definition, force: true)),
             :ok <- delete_step(job_id, :schedules, Schedules.delete_job_schedules(job_id)),
             :ok <-
               delete_step(
                 job_id,
                 :historical_runs,
                 RunCleanup.delete_historical_runs(definition)
               ),
             :ok <-
               delete_step(
                 job_id,
                 :definition_native_resources,
                 cleanup_definition_native_resources(job_id, definition)
               ),
             :ok <-
               delete_step(
                 job_id,
                 :shared_storage,
                 SharedStorage.cleanup_manifest(job_id, definition["manifest"])
               ),
             :ok <- delete_step(job_id, :job_data, JobData.delete(job_id)),
             :ok <-
               delete_step(job_id, :definition_record, RedisStore.delete_job_definition(job_id)) do
          {:ok, definition_resource_descriptor(definition)}
        end
      end)
    else
      {:error, :confirmation_required}
    end
  end

  defp delete_step(_job_id, _stage, :ok), do: :ok

  defp delete_step(job_id, stage, {:error, reason} = error) do
    Logger.warning("stable job deletion failed for #{job_id} at #{stage}: #{inspect(reason)}")

    error
  end

  defp delete_step(job_id, stage, other) do
    Logger.warning(
      "stable job deletion returned an invalid result for #{job_id} at #{stage}: #{inspect(other)}"
    )

    other
  end

  defp normalize_update(definition, attrs) do
    if Map.has_key?(attrs, "storage") do
      with :ok <- DataAccess.ensure_no_active_runs(definition),
           {:ok, bundle} <- Runs.load_bundle(definition),
           {:ok, storage} <- Storage.storage_declarations(bundle, attrs["storage"]) do
        {:ok, Map.put(attrs, "storage", storage)}
      end
    else
      {:ok, attrs}
    end
  end

  def blueprint_id(manifest) do
    get_in(manifest.metadata || %{}, ["blueprint_id"]) || manifest.graph_id
  end

  defp ensure_same_bundle_identity(definition, bundle) do
    current = {definition["graph_id"], definition["blueprint_id"]}
    replacement = {bundle.manifest.graph_id, blueprint_id(bundle.manifest)}

    if current == replacement,
      do: :ok,
      else: {:error, {:job_bundle_identity_mismatch, current, replacement}}
  end

  defp definition_resource_descriptor(definition) do
    metadata = get_in(definition, ["manifest", "metadata"]) || %{}

    %{
      "metadata" =>
        Map.take(metadata, [
          "mn_storage",
          "mn_docker_workers",
          "mn_docker_worker_shared_contexts",
          "mn_docker_compose",
          "mn_docker_compose_shared_contexts",
          "mn_native_resources"
        ])
    }
  end

  defp cleanup_definition_native_resources(job_id, definition) do
    with :ok <- RunnerResources.cleanup_retired_native_resources(definition, %{}),
         :ok <- RunnerResources.cleanup_native_resources(job_id) do
      :ok
    end
  end

  defp maybe_put_resource_cleanup_errors(definition, []), do: definition

  defp maybe_put_resource_cleanup_errors(definition, errors),
    do: Map.put(definition, "resource_cleanup_errors", errors)
end
