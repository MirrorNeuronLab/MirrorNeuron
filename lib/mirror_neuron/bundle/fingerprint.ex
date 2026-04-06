defmodule MirrorNeuron.Bundle.Fingerprint do
  @moduledoc """
  Calculates a fingerprint for a job bundle to detect changes.
  Uses SHA-256 over the manifest and all files in the payloads directory.
  """

  def compute(bundle_path) when is_binary(bundle_path) do
    manifest_path = Path.join(bundle_path, "manifest.json")
    payloads_path = Path.join(bundle_path, "payloads")

    if File.exists?(manifest_path) do
      hash = :crypto.hash_init(:sha256)
      hash = add_file_to_hash(hash, manifest_path)

      hash =
        if File.dir?(payloads_path) do
          payloads_path
          |> Path.join("**/*")
          |> Path.wildcard()
          |> Enum.filter(&File.regular?/1)
          |> Enum.sort()
          |> Enum.reduce(hash, &add_file_to_hash(&2, &1))
        else
          hash
        end

      {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
    else
      {:error, :missing_manifest}
    end
  end

  def compute(_), do: {:error, :invalid_path}

  defp add_file_to_hash(hash, path) do
    # Incorporate relative path and file contents
    # This prevents collisions if files are moved around
    hash = :crypto.hash_update(hash, Path.basename(path))

    case File.read(path) do
      {:ok, content} -> :crypto.hash_update(hash, content)
      _ -> hash
    end
  end
end
