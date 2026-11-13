defmodule MirrorNeuron.Persistence.RedisStore.Bundles do
  @moduledoc "Bundle archive records and liveness derived from durable references."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.ScheduleIndex
  alias MirrorNeuron.Persistence.RedisStore.Values

  def persist_bundle_archive(fingerprint, archive) do
    archive = Map.put(archive, "fingerprint", fingerprint)

    with {:ok, "OK"} <-
           Connection.command(["SET", Keys.key("bundle", fingerprint), Jason.encode!(archive)]),
         :ok <-
           Connection.expire_key(
             Keys.key("bundle", fingerprint),
             RetentionPolicy.bundle_archive_ttl_seconds()
           ),
         :ok <- Connection.wait_for_replicas() do
      {:ok, archive}
    end
  end

  def fetch_bundle_archive(fingerprint) do
    case Connection.command(["GET", Keys.key("bundle", fingerprint)]) do
      {:ok, nil} -> {:error, "bundle archive #{fingerprint} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def refresh_bundle_archive(fingerprint) when is_binary(fingerprint) and fingerprint != "" do
    redis_key = Keys.key("bundle", fingerprint)

    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      return 0
    end

    redis.call("persist", KEYS[1])
    return 1
    """

    case Connection.command(["EVAL", script, "1", redis_key]) do
      {:ok, 1} -> Connection.wait_for_replicas()
      {:ok, 0} -> {:error, :not_found}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def refresh_bundle_archive(_fingerprint), do: {:error, :invalid_fingerprint}

  def expire_unreferenced_bundle_archives(referenced_fingerprints) do
    referenced = MapSet.new(referenced_fingerprints)
    ttl_seconds = RetentionPolicy.bundle_archive_ttl_seconds()

    if is_integer(ttl_seconds) and ttl_seconds > 0 do
      with {:ok, archive_keys} <- Connection.scan_keys(Keys.key("bundle", "*")),
           archive_refs <-
             archive_keys
             |> Enum.flat_map(&Keys.bundle_archive_ref_from_key/1)
             |> Enum.reject(fn {fingerprint, _redis_key} ->
               MapSet.member?(referenced, fingerprint)
             end),
           {:ok, transitioned} <- expire_persistent_bundle_archives(archive_refs, ttl_seconds),
           :ok <- Connection.maybe_wait_for_deleted_keys(transitioned) do
        {:ok, transitioned}
      else
        {:error, reason} -> {:error, Values.format_reason(reason)}
        other -> {:error, Values.format_reason(other)}
      end
    else
      {:ok, 0}
    end
  end

  def referenced_bundle_fingerprints do
    with {:ok, redis_job_keys} <- Connection.scan_keys(Keys.key("job", "*")),
         job_ids <- redis_job_keys |> Enum.flat_map(&Keys.root_job_id_from_key/1) |> Enum.uniq(),
         {:ok, schedule_ids} <- ScheduleIndex.raw_schedule_index_ids(),
         {:ok, version_keys} <-
           Connection.scan_keys(Keys.key("deployment", "key", "*", "version", "*")),
         reference_keys <-
           Enum.map(job_ids, &Keys.key("job", &1)) ++
             Enum.map(schedule_ids, &Keys.key("schedule", &1)) ++ version_keys,
         {:ok, records} <- fetch_bundle_reference_records(reference_keys) do
      fingerprints =
        records
        |> Enum.flat_map(&bundle_fingerprints/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, fingerprints}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  defp fetch_bundle_reference_records([]), do: {:ok, []}

  defp fetch_bundle_reference_records(redis_keys) do
    redis_keys
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, records} ->
      case fetch_bundle_reference_chunk(chunk) do
        {:ok, chunk_records} -> {:cont, {:ok, [chunk_records | records]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_bundle_reference_chunk(redis_keys) do
    case Connection.command(["MGET" | redis_keys]) do
      {:ok, encoded_records} ->
        redis_keys
        |> Enum.zip(encoded_records)
        |> Enum.reduce_while({:ok, []}, fn
          {_redis_key, nil}, {:ok, records} ->
            {:cont, {:ok, records}}

          {redis_key, encoded}, {:ok, records} ->
            case Jason.decode(encoded) do
              {:ok, record} when is_map(record) ->
                {:cont, {:ok, [record | records]}}

              {:ok, _invalid} ->
                {:halt, {:error, {:invalid_bundle_reference_record, redis_key}}}

              {:error, reason} ->
                {:halt, {:error, {:unreadable_bundle_reference_record, redis_key, reason}}}
            end
        end)
        |> reverse_record_result()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reverse_record_result({:ok, records}), do: {:ok, Enum.reverse(records)}

  defp reverse_record_result({:error, _reason} = error), do: error

  defp bundle_fingerprints(record) do
    [
      get_in(record, ["manifest_ref", "bundle_fingerprint"]),
      get_in(record, ["bundle_ref", "bundle_fingerprint"]),
      Map.get(record, "bundle_fingerprint")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp expire_persistent_bundle_archives(archive_refs, ttl_seconds) do
    Enum.reduce_while(archive_refs, {:ok, 0}, fn {_fingerprint, redis_key}, {:ok, count} ->
      case Connection.command(["TTL", redis_key]) do
        {:ok, -1} ->
          case Connection.command(["EXPIRE", redis_key, to_string(ttl_seconds)]) do
            {:ok, 1} -> {:cont, {:ok, count + 1}}
            {:ok, 0} -> {:cont, {:ok, count}}
            {:error, reason} -> {:halt, {:error, reason}}
            other -> {:halt, {:error, other}}
          end

        {:ok, ttl} when is_integer(ttl) ->
          {:cont, {:ok, count}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, other}}
      end
    end)
  end
end
