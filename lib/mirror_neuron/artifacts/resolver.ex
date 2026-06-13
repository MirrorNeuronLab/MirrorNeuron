defmodule MirrorNeuron.Artifacts.Resolver do
  @moduledoc false

  alias MirrorNeuron.Artifacts.{BlobRef, BlobStore, JobStore}
  alias MirrorNeuron.PathSafety

  def resolve_ref(ref) do
    ref = BlobRef.normalize(ref)
    sha256 = Map.get(ref, "sha256")

    cond do
      not BlobRef.valid?(ref) ->
        {:error, "invalid blob ref #{inspect(ref)}"}

      BlobStore.valid?(sha256) ->
        {:ok, BlobStore.path(sha256)}

      BlobStore.has?(sha256) ->
        {:error, "blob #{sha256} is corrupt in shared blob store #{BlobStore.root()}"}

      true ->
        {:error, "blob #{sha256} is missing from shared blob store #{BlobStore.root()}"}
    end
  end

  def materialize_payload_refs(refs, prefix, target, opts \\ []) do
    selected = BlobRef.refs_for_payload_prefix(refs, prefix)

    if selected == [] do
      :not_found
    else
      result =
        Enum.reduce_while(selected, :ok, fn ref, :ok ->
          suffix = BlobRef.payload_suffix(ref, prefix)

          with {:ok, destination} <- destination_path(target, suffix),
               {:ok, local_path} <- resolve_ref(ref),
               {:ok, materialized_path} <- maybe_materialize_job_blob(local_path, suffix, opts),
               :ok <- BlobStore.materialize_file(materialized_path, destination) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> :ok
        error -> error
      end
    end
  end

  defp maybe_materialize_job_blob(local_path, suffix, opts) do
    case Keyword.get(opts, :job_id) do
      job_id when job_id in [nil, ""] ->
        {:ok, local_path}

      job_id ->
        JobStore.materialize_blob(job_id, suffix, local_path)
    end
  end

  defp destination_path(target, suffix) when suffix in [nil, ""], do: {:ok, target}

  defp destination_path(target, suffix) do
    target = Path.expand(target)
    suffix = normalize_suffix(suffix)

    cond do
      PathSafety.unsafe_relative_path?(suffix) ->
        {:error, "unsafe artifact path #{inspect(suffix)}"}

      true ->
        destination = Path.expand(Path.join(target, suffix))

        if destination == target or String.starts_with?(destination, target <> "/") do
          {:ok, destination}
        else
          {:error, "unsafe artifact path #{inspect(suffix)}"}
        end
    end
  end

  defp normalize_suffix(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.trim()
    |> String.trim_leading("/")
  end
end
