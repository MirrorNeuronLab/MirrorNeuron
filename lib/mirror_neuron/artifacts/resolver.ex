defmodule MirrorNeuron.Artifacts.Resolver do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Artifacts.{BlobRef, BlobStore, Registry}

  @http_timeout_ms 120_000

  def resolve_ref(ref) do
    ref = BlobRef.normalize(ref)
    sha256 = Map.get(ref, "sha256")

    cond do
      not BlobRef.valid?(ref) ->
        {:error, "invalid blob ref #{inspect(ref)}"}

      BlobStore.valid?(sha256) ->
        {:ok, BlobStore.path(sha256)}

      true ->
        fetch_ref(ref)
    end
  end

  def materialize_payload_refs(refs, prefix, target) do
    selected = BlobRef.refs_for_payload_prefix(refs, prefix)

    if selected == [] do
      :not_found
    else
      result =
        Enum.reduce_while(selected, :ok, fn ref, :ok ->
          suffix = BlobRef.payload_suffix(ref, prefix)
          destination = destination_path(target, suffix)

          with {:ok, local_path} <- resolve_ref(ref),
               :ok <- copy_blob(local_path, destination) do
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

  defp fetch_ref(ref) do
    sha256 = Map.fetch!(ref, "sha256")

    locations =
      ref_locations(ref) ++
        case Registry.resolve(sha256) do
          {:ok, %{"locations" => locations}} when is_list(locations) -> locations
          _ -> []
        end

    locations
    |> Enum.uniq_by(&Map.get(&1, "url"))
    |> Enum.reduce_while({:error, "blob #{sha256} has no reachable locations"}, fn location,
                                                                                   _last_error ->
      case fetch_location(ref, location) do
        {:ok, path} -> {:halt, {:ok, path}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp ref_locations(ref) do
    ref
    |> Map.get("locations", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp fetch_location(ref, %{"url" => url}) when is_binary(url) and url != "" do
    sha256 = Map.fetch!(ref, "sha256")

    tmp_path =
      Path.join(System.tmp_dir!(), "mn_blob_#{sha256}_#{System.unique_integer([:positive])}")

    headers = auth_headers()

    :inets.start()

    request = {String.to_charlist(url), headers}

    result =
      case :httpc.request(:get, request, [timeout: @http_timeout_ms],
             body_format: :binary,
             stream: String.to_charlist(tmp_path)
           ) do
        {:ok, :saved_to_file} ->
          store_download(tmp_path, sha256)

        {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
          File.write!(tmp_path, body)
          store_download(tmp_path, sha256)

        {:ok, {{_version, status, _reason}, _headers, _body}} ->
          {:error, "artifact fetch #{url} returned HTTP #{status}"}

        {:error, reason} ->
          {:error, "artifact fetch #{url} failed: #{inspect(reason)}"}
      end

    _ = File.rm(tmp_path)
    result
  end

  defp fetch_location(_ref, _location), do: {:error, "artifact location is missing url"}

  defp store_download(tmp_path, sha256) do
    case BlobStore.put_file(tmp_path, sha256) do
      {:ok, %{path: path}} ->
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers do
    case Registry.auth_token() do
      token when is_binary(token) and token != "" ->
        [{~c"authorization", String.to_charlist("Bearer #{token}")}]

      _ ->
        []
    end
  end

  defp destination_path(target, suffix) when suffix in [nil, ""], do: target
  defp destination_path(target, suffix), do: Path.join(target, suffix)

  defp copy_blob(source, destination) do
    File.mkdir_p!(Path.dirname(destination))

    case File.cp(source, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "failed to materialize blob #{source} to #{destination}: #{inspect(reason)}"}
    end
  end
end
