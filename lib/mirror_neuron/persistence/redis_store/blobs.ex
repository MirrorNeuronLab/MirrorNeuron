defmodule MirrorNeuron.Persistence.RedisStore.Blobs do
  @moduledoc "Blob location metadata and stale content-reference indexes."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.Values

  def register_blob_ref(ref) when is_map(ref) do
    ref = Values.stringify_map(ref)
    sha256 = Map.get(ref, "sha256")

    with true <- is_binary(sha256) and sha256 != "",
         existing <- existing_blob_ref(sha256),
         blob <- merge_blob_ref(existing, ref),
         {:ok, "OK"} <- Connection.command(["SET", Keys.key("blob", sha256), Jason.encode!(blob)]),
         {:ok, _count} <- Connection.command(["SADD", Keys.key("blobs"), sha256]),
         :ok <-
           Connection.expire_key(Keys.key("blob", sha256), RetentionPolicy.blob_ref_ttl_seconds()),
         :ok <- Connection.wait_for_replicas() do
      {:ok, blob}
    else
      false -> {:error, "blob ref requires sha256"}
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  def fetch_blob_ref(sha256) when is_binary(sha256) do
    case Connection.command(["GET", Keys.key("blob", sha256)]) do
      {:ok, nil} -> {:error, "blob #{sha256} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def list_blob_refs do
    with {:ok, %{active_blob_refs: sha_values}} <- sweep_blob_ref_index() do
      refs =
        sha_values
        |> Enum.sort()
        |> Enum.map(fn sha256 ->
          case fetch_blob_ref(sha256) do
            {:ok, ref} -> ref
            {:error, _reason} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, refs}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def sweep_blob_ref_index do
    with {:ok, sha_values} <- Connection.command(["SMEMBERS", Keys.key("blobs")]),
         {:ok, existence} <- blob_ref_existence(sha_values),
         :ok <- Results.expect_no_redis_errors(existence),
         {active, stale} <- partition_blob_refs(sha_values, existence),
         :ok <- remove_stale_blob_ref_indexes(stale) do
      stale = Enum.sort(stale)

      {:ok,
       %{
         active_blob_refs: Enum.sort(active),
         stale_blob_ref_count: length(stale),
         stale_blob_refs: stale
       }}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  defp blob_ref_existence([]), do: {:ok, []}

  defp blob_ref_existence(sha_values) do
    Connection.pipeline(Enum.map(sha_values, &["EXISTS", Keys.key("blob", &1)]))
  end

  defp partition_blob_refs(sha_values, existence) do
    sha_values
    |> Enum.zip(existence)
    |> Enum.reduce({[], []}, fn
      {sha256, 1}, {active, stale} -> {[sha256 | active], stale}
      {sha256, 0}, {active, stale} -> {active, [sha256 | stale]}
    end)
  end

  defp remove_stale_blob_ref_indexes([]), do: :ok

  defp remove_stale_blob_ref_indexes(stale) do
    case Connection.command(["SREM", Keys.key("blobs") | stale]) do
      {:ok, _removed} -> :ok
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp existing_blob_ref(sha256) do
    case fetch_blob_ref(sha256) do
      {:ok, existing} when is_map(existing) -> existing
      _ -> %{}
    end
  end

  defp merge_blob_ref(existing, incoming) do
    now = Values.timestamp()

    existing
    |> Map.merge(Map.drop(incoming, ["locations"]))
    |> Map.put("sha256", incoming["sha256"])
    |> Map.put_new("created_at", now)
    |> Map.put("updated_at", now)
    |> Map.put("locations", merge_blob_locations(existing["locations"], incoming["locations"]))
  end

  defp merge_blob_locations(existing, incoming) do
    (List.wrap(existing) ++ List.wrap(incoming))
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Values.stringify_map/1)
    |> Enum.filter(&valid_blob_location?/1)
    |> Enum.reverse()
    |> Enum.uniq_by(fn location ->
      {
        Map.get(location, "node"),
        Map.get(location, "storage") || Map.get(location, "type"),
        Map.get(location, "path"),
        Map.get(location, "url")
      }
    end)
    |> Enum.reverse()
  end

  defp valid_blob_location?(location) do
    url = Map.get(location, "url")
    storage = Map.get(location, "storage") || Map.get(location, "type")
    path = Map.get(location, "path")

    (is_binary(url) and url != "") or
      (storage in ["shared_fs", "shared_fs_cas"] and is_binary(path) and path != "")
  end
end
