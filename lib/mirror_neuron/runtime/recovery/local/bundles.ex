defmodule MirrorNeuron.Runtime.LocalRecovery.Bundles do
  @moduledoc "Loads durable or embedded executable definitions for local recovery."

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.JobBundle

  def load_recovery_bundle(job) do
    manifest_ref = job["manifest_ref"] || %{}
    fingerprint = manifest_ref["bundle_fingerprint"] || manifest_ref[:bundle_fingerprint]
    job_path = manifest_ref["job_path"] || manifest_ref[:job_path]

    cond do
      is_binary(fingerprint) and fingerprint != "" ->
        case Archive.load(fingerprint) do
          {:ok, bundle} -> {:ok, bundle}
          {:error, _reason} when is_binary(job_path) -> JobBundle.load_filesystem_path(job_path)
          {:error, _reason} -> load_embedded_manifest(job)
        end

      is_binary(job_path) ->
        JobBundle.load_filesystem_path(job_path)

      true ->
        load_embedded_manifest(job)
    end
  end

  defp load_embedded_manifest(%{"manifest" => manifest}) when is_map(manifest) do
    JobBundle.load(manifest)
  end

  defp load_embedded_manifest(_job), do: {:error, :missing_recovery_manifest}
end
