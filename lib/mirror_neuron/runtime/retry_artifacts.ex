defmodule MirrorNeuron.Runtime.RetryArtifacts do
  @moduledoc false
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Runner.OpenShellArtifactStore

  def capture(job, ledger, manifest) do
    previous =
      case MirrorNeuron.Persistence.RedisStore.fetch_run_checkpoint(job["job_id"]) do
        {:ok, checkpoint} -> checkpoint["artifacts"] || %{}
        _ -> %{}
      end

    case inspect_artifacts(job, ledger, manifest, [], "capture", previous) do
      {:ok, result} -> result
      {:error, reason} -> %{"error" => reason}
    end
  end

  def verify(job, ledger, manifest, handoff_steps, artifacts \\ %{}) do
    if artifacts["error"] do
      {:error, "A checkpoint artifact could not be retained. Start a new run."}
    else
      case inspect_artifacts(job, ledger, manifest, handoff_steps, "verify", artifacts) do
        {:ok, result} -> {:ok, result["safe_handoff_steps"] || []}
        error -> error
      end
    end
  end

  defp inspect_artifacts(job, ledger, manifest, handoff_steps, mode, artifacts) do
    ledger = materialize(ledger)
    storage = manifest.metadata["mn_storage"] || %{}

    if is_binary(storage["submission_path"]) do
      temporary =
        Path.join(System.tmp_dir!(), "mn-retry-#{System.unique_integer([:positive])}.json")

      try do
        request = %{
          "trusted_root" => SharedStorage.root(),
          "submission_path" => storage["submission_path"],
          "run_ids" => Enum.uniq([job["run_id"] || job["job_id"], ledger["run_id"]]),
          "workflow_run_id" => ledger["run_id"],
          "workflow" => ledger,
          "handoff_steps" => handoff_steps,
          "mode" => mode,
          "artifacts" => artifacts
        }

        File.write!(temporary, Jason.encode!(request))

        task =
          Task.async(fn ->
            System.cmd(
              "python3",
              [Path.join(OpenShellArtifactStore.helper_dir(), "retry_verify.py"), temporary],
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            case Jason.decode(output) do
              {:ok, %{"ok" => result}} when is_map(result) -> {:ok, result}
              _ -> {:error, "Checkpoint artifacts could not be verified."}
            end

          _ ->
            {:error, "Checkpoint artifacts or replay receipts are missing or invalid."}
        end
      after
        File.rm(temporary)
      end
    else
      if has_file_references?(ledger) or handoff_steps != [],
        do: {:error, "The retained artifact storage location is missing."},
        else: {:ok, %{"safe_handoff_steps" => [], "inventory" => []}}
    end
  rescue
    _ -> {:error, "Checkpoint artifacts could not be verified."}
  end

  defp materialize(value) when is_map(value) do
    if StagedArtifact.ref?(value),
      do: value |> StagedArtifact.resolve!(timeout_ms: 0) |> materialize(),
      else: Map.new(value, fn {key, item} -> {key, materialize(item)} end)
  end

  defp materialize(value) when is_list(value), do: Enum.map(value, &materialize/1)
  defp materialize(value), do: value

  defp has_file_references?(value) when is_map(value) do
    (is_binary(value["path"]) and (is_binary(value["sha256"]) or is_binary(value["kind"]))) or
      Enum.any?(Map.values(value), &has_file_references?/1)
  end

  defp has_file_references?(value) when is_list(value),
    do: Enum.any?(value, &has_file_references?/1)

  defp has_file_references?(_), do: false
end
