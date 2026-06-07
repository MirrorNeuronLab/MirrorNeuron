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

    if is_binary(sha256) and BlobStore.has?(sha256) do
      case artifact_url(sha256) do
        nil ->
          nil

        url ->
          %{
            "node" => to_string(Node.self()),
            "url" => url,
            "size_bytes" => Map.get(ref, "size_bytes"),
            "media_type" => Map.get(ref, "media_type"),
            "status" => "available",
            "updated_at" => MirrorNeuron.Runtime.timestamp()
          }
      end
    end
  end

  def artifact_url(sha256) do
    base = advertise_url()

    if base && is_binary(sha256) do
      "#{String.trim_trailing(base, "/")}/blobs/#{sha256}"
    end
  end

  def advertise_url do
    configured =
      System.get_env("MN_ARTIFACT_ADVERTISE_URL") ||
        Application.get_env(:mirror_neuron, :artifact_advertise_url)

    cond do
      is_binary(configured) and String.trim(configured) != "" ->
        String.trim(configured)

      host = advertise_host() ->
        port =
          System.get_env("MN_ARTIFACT_PORT") ||
            Application.get_env(:mirror_neuron, :artifact_port, 55_660)

        "http://#{host}:#{port}"

      true ->
        nil
    end
  end

  def node_advertisement do
    case advertise_url() do
      nil ->
        %{}

      url ->
        %{
          "artifact_store" => %{
            "type" => "peer_http_cas",
            "url" => url,
            "node" => to_string(Node.self())
          }
        }
    end
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

  defp advertise_host do
    [
      System.get_env("MN_NETWORK_ADVERTISE_HOST"),
      System.get_env("MN_ARTIFACT_ADVERTISE_HOST")
    ]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end
end
