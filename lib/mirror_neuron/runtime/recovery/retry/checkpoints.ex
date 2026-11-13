defmodule MirrorNeuron.Runtime.RunRetry.Checkpoints do
  @moduledoc "Versioned checkpoint creation, canonical digests and durable identity verification."

  alias MirrorNeuron.Runtime.RunRetry.Configuration
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Artifacts.StagedArtifact

  @version "mn.run_checkpoint/v1"

  def checkpoint(job, ledger, artifacts \\ %{}) do
    checkpoint(job, ledger, artifacts, definition_identity(job["manifest"], job["inputs"]))
  end

  def definition_identity(manifest, inputs), do: {digest(manifest), digest(inputs)}

  def checkpoint(job, ledger, artifacts, {manifest_digest, inputs_digest}) do
    %{
      "version" => @version,
      "run_id" => job["run_id"] || job["job_id"],
      "job_id" => job["stable_job_id"],
      "attempt" => job["attempt"],
      "data_generation" => job["data_generation"],
      "manifest_digest" => manifest_digest,
      "inputs_digest" => inputs_digest,
      "running_time" => job["running_time"],
      "configuration_overrides" => Configuration.effective_overrides(job),
      "workflow" => ledger,
      "artifacts" => artifacts,
      "created_at" => Runtime.timestamp()
    }
    |> then(&Map.put(&1, "revision", digest(&1)))
  end

  def load_checkpoint(job) do
    case RedisStore.fetch_run_checkpoint(job["job_id"]) do
      {:ok, checkpoint} ->
        {:ok, checkpoint}

      {:error, :checkpoint_not_found} ->
        if StagedArtifact.ref?(job["workflow_state_ref"]) do
          ledger = StagedArtifact.resolve!(job["workflow_state_ref"], timeout_ms: 0)
          {:ok, checkpoint(job, ledger)}
        else
          {:error, "History is available, but no durable checkpoint remains. Start a new run."}
        end

      error ->
        error
    end
  rescue
    _ -> {:error, "Checkpoint artifacts are missing or could not be verified."}
  end

  def checkpoint_identity(job, checkpoint) do
    if checkpoint["version"] == @version and
         checkpoint["run_id"] == (job["run_id"] || job["job_id"]) and
         checkpoint["job_id"] == job["stable_job_id"] and checkpoint["attempt"] == job["attempt"] and
         checkpoint["data_generation"] == job["data_generation"] and
         checkpoint["manifest_digest"] == digest(job["manifest"]) and
         checkpoint["inputs_digest"] == digest(job["inputs"]) and
         checkpoint["revision"] == digest(Map.delete(checkpoint, "revision")),
       do: :ok,
       else: {:error, "Checkpoint identity or integrity does not match this run."}
  end

  def digest(value),
    do:
      value
      |> canonical()
      |> Jason.encode_to_iodata!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp canonical(value) when is_map(value),
    do:
      value
      |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [k, v] end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value), do: value
end
