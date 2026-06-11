defmodule MirrorNeuron.Artifacts.Registry do
  @moduledoc false

  alias MirrorNeuron.Artifacts.{BlobRef, BlobStore}
  alias MirrorNeuron.Persistence.RedisStore

  def register_manifest_refs(manifest_or_map) do
    manifest_or_map
    |> BlobRef.collect()
    |> Enum.each(&register_blob_ref/1)

    :ok
  end

  def register_blob_ref(ref) when is_map(ref) do
    ref = BlobRef.normalize(ref)

    if BlobRef.valid?(ref) do
      ref
      |> with_local_location()
      |> RedisStore.register_blob_ref()
    else
      {:error, :invalid_blob_ref}
    end
  end

  def register_blob_ref(_ref), do: {:error, :invalid_blob_ref}

  def resolve(sha256), do: RedisStore.fetch_blob_ref(sha256)

  def local_location(ref) do
    sha256 = Map.get(ref, "sha256")

    if is_binary(sha256) and BlobStore.valid?(sha256) do
      %{
        "node" => to_string(Node.self()),
        "storage" => "shared_fs",
        "root" => "blob_store",
        "path" => BlobStore.relative_path(sha256),
        "size_bytes" => Map.get(ref, "size_bytes"),
        "media_type" => Map.get(ref, "media_type"),
        "status" => "available",
        "updated_at" => MirrorNeuron.Runtime.timestamp()
      }
    end
  end

  def node_advertisement do
    %{
      "artifact_store" => %{
        "type" => "shared_fs_cas",
        "root" => "blob_store",
        "path_layout" => "sha256-prefix",
        "node" => to_string(Node.self())
      }
    }
  end

  defp with_local_location(ref) do
    case local_location(ref) do
      nil ->
        ref

      location ->
        Map.update(ref, "locations", [location], fn locations ->
          [location | List.wrap(locations)]
        end)
    end
  end
end
