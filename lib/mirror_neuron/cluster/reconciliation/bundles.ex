defmodule MirrorNeuron.Cluster.Reconciler.Bundles do
  @moduledoc "Loads durable recovery bundles from Redis or shared filesystem references."

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.JobBundle

  def load_recovery_bundle(job, opts) do
    case Keyword.get(opts, :bundle_loader) do
      loader when is_function(loader, 1) -> loader.(job)
      _ -> load_durable_bundle(job)
    end
  end

  defp load_durable_bundle(job) do
    manifest_ref = job["manifest_ref"] || %{}
    storage = manifest_ref["bundle_storage"] || manifest_ref[:bundle_storage]
    fingerprint = manifest_ref["bundle_fingerprint"] || manifest_ref[:bundle_fingerprint]
    shared_path = shared_bundle_path(manifest_ref)

    cond do
      storage == "redis" and is_binary(fingerprint) and fingerprint != "" ->
        Archive.load(fingerprint)

      storage in ["shared_fs", "shared_fs_cas"] and is_binary(shared_path) and shared_path != "" ->
        JobBundle.load_filesystem_path(shared_path)

      true ->
        {:error, :missing_durable_bundle_reference}
    end
  end

  defp shared_bundle_path(manifest_ref) do
    Map.get(manifest_ref, "cache_path") ||
      Map.get(manifest_ref, :cache_path) ||
      Map.get(manifest_ref, "job_path") ||
      Map.get(manifest_ref, :job_path)
  end
end
