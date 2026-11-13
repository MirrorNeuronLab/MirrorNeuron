defmodule MirrorNeuron.Runtime.RunRetry.Planner do
  @moduledoc "Checks retry eligibility, executable inputs, data generation and remaining active owners."

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Runtime.RunRetry.Checkpoints
  alias MirrorNeuron.Runtime.RunRetry.Configuration
  alias MirrorNeuron.Bundle.Fingerprint
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.RunRetry.Safety
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Runtime.WorkflowRetry

  def plan(run_id, overrides \\ %{}) do
    with {:ok, job} <- RedisStore.fetch_job(run_id) do
      case prepare(job, overrides) do
        {:ok, prepared} ->
          {:ok, public_plan(job, prepared)}

        {:error, reason} ->
          {:ok,
           %{
             "run_id" => run_id,
             "job_id" => job["stable_job_id"],
             "eligible" => false,
             "reason" => if(is_binary(reason), do: reason, else: Runtime.error_message(reason)),
             "preserved_steps" => [],
             "retry_steps" => []
           }}
      end
    end
  end

  def prepare(job, overrides) do
    with :ok <- failed(job),
         {:ok, checkpoint} <- Checkpoints.load_checkpoint(job),
         :ok <- Checkpoints.checkpoint_identity(job, checkpoint),
         {:ok, manifest} <- Manifest.load(job["manifest"]),
         {:ok, bundle} <- verified_bundle(job, manifest),
         :ok <- generation(job),
         :ok <- verified_inputs(manifest),
         :ok <- inactive(job),
         :ok <- Configuration.validate_overrides(manifest, overrides),
         {:ok, _restored} <- WorkflowRetry.restore(checkpoint["workflow"], Runtime.timestamp()),
         :ok <- Safety.completed_work_matches(job, checkpoint["workflow"]),
         :ok <- Safety.verify_references(checkpoint["workflow"]),
         :ok <- Safety.verify_boundaries(checkpoint["workflow"]),
         :ok <-
           Safety.safe_work(job, checkpoint["workflow"], manifest, checkpoint["artifacts"] || %{}) do
      {:ok,
       %{
         checkpoint: checkpoint,
         ledger: checkpoint["workflow"],
         bundle: bundle,
         fields: Configuration.effective_fields(job, manifest)
       }}
    end
  rescue
    _ -> {:error, "Checkpoint data is invalid or incomplete. Start a new run."}
  end

  defp failed(%{"status" => "failed"}), do: :ok

  defp failed(_), do: {:error, "Only failed runs can be retried. Resume a paused run instead."}

  defp verified_bundle(job, manifest) do
    fingerprint = get_in(job, ["manifest_ref", "bundle_fingerprint"])

    if is_binary(fingerprint) and fingerprint != "" do
      with {:ok, bundle} <- Archive.load(fingerprint),
           {:ok, ^fingerprint} <- Fingerprint.compute(bundle.root_path) do
        {:ok, %{bundle | manifest: manifest}}
      else
        _ -> {:error, "The original executable bundle is missing or changed."}
      end
    else
      JobBundle.load(Manifest.to_map(manifest))
    end
  end

  defp generation(%{"stable_job_id" => id} = job) when is_binary(id) do
    with {:ok, definition} <- StableJob.get(id),
         true <-
           definition["status"] == "active" and
             List.wrap(definition["resource_cleanup_errors"]) == [] and
             definition["data_generation"] == job["data_generation"] do
      :ok
    else
      _ -> {:error, "Job data was reset or the co-worker is no longer active."}
    end
  end

  defp generation(_), do: :ok

  defp verified_inputs(manifest) do
    case MirrorNeuron.Artifacts.SubmissionReadiness.verify(Manifest.to_map(manifest)) do
      {:ready, _} ->
        :ok

      _ ->
        {:error,
         "Original staged inputs are missing or changed. Restore them or start a new run."}
    end
  end

  def inactive(job) do
    runner = Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job["job_id"]})
    coordinator = Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job["job_id"]})

    with [] <- runner,
         [] <- coordinator,
         {:ok, nil} <- RedisStore.get_lease("job:#{job["job_id"]}") do
      if is_binary(job["stable_job_id"]) do
        with {:ok, runs} <- StableJob.list_runs(job["stable_job_id"]) do
          if Enum.any?(
               runs,
               &(&1["run_id"] != (job["run_id"] || job["job_id"]) and
                   &1["status"] in ~w(queued pending running paused cancelling))
             ),
             do:
               {:error, {:run_retry_blocked, "Another run is active. Stop it before retrying."}},
             else: :ok
        end
      else
        :ok
      end
    else
      _ ->
        {:error,
         {:run_retry_blocked, "Previous attempt cleanup or another execution is still active."}}
    end
  end

  defp public_plan(job, prepared) do
    %{
      "run_id" => job["run_id"] || job["job_id"],
      "job_id" => job["stable_job_id"],
      "eligible" => true,
      "reason" => nil,
      "expected_attempt" => job["attempt"],
      "checkpoint_revision" => prepared.checkpoint["revision"],
      "preserved_steps" => WorkflowRetry.preserved(prepared.ledger),
      "retry_steps" => WorkflowRetry.unfinished(prepared.ledger),
      "configuration_fields" => prepared.fields,
      "running_time" => job["running_time"],
      "retained_bytes" => byte_size(Jason.encode!(prepared.checkpoint))
    }
  end
end
