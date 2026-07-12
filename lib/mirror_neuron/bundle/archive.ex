defmodule MirrorNeuron.Bundle.Archive do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Bundle.Fingerprint
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.PathSafety
  alias MirrorNeuron.Persistence.RedisStore

  @default_max_bytes 50 * 1024 * 1024
  @default_cache_ttl_seconds 7 * 24 * 60 * 60
  @fingerprint_pattern ~r/\A[0-9a-f]{64}\z/

  def store(%JobBundle{root_path: root_path} = bundle) when is_binary(root_path) do
    case Fingerprint.compute(root_path) do
      {:ok, fingerprint} ->
        case store_with_fingerprint(bundle, fingerprint) do
          {:ok, _archive_ref} = result ->
            _ = touch_cache(fingerprint)
            result

          {:error, _reason} = error ->
            error
        end

      {:error, reason} ->
        Logger.warning("failed to archive bundle for cluster recovery: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def store(_bundle), do: {:error, :bundle_has_no_root_path}

  def load(fingerprint) when is_binary(fingerprint) and fingerprint != "" do
    if valid_fingerprint?(fingerprint) do
      load_valid_fingerprint(fingerprint)
    else
      {:error, :invalid_bundle_fingerprint}
    end
  end

  def load(_fingerprint), do: {:error, :missing_bundle_fingerprint}

  defp load_valid_fingerprint(fingerprint) do
    path = cache_path(fingerprint)

    case JobBundle.load(path) do
      {:ok, bundle} ->
        _ = touch_cache(fingerprint)
        {:ok, bundle}

      {:error, _cache_reason} ->
        with {:ok, archive} <- RedisStore.fetch_bundle_archive(fingerprint),
             :ok <- restore_to_cache(fingerprint, archive),
             {:ok, bundle} <- JobBundle.load(path),
             :ok <- touch_cache(fingerprint) do
          {:ok, bundle}
        end
    end
  end

  def cache_path(fingerprint), do: Path.join(cache_root(), fingerprint)

  def sweep_retention(opts \\ []) do
    with {:ok, fingerprints} <- RedisStore.referenced_bundle_fingerprints(),
         {:ok, retained} <- retain_referenced_archives(fingerprints),
         {:ok, expiring_count} <-
           RedisStore.expire_unreferenced_bundle_archives(fingerprints),
         {:ok, reclaimed} <- reclaim_unreferenced_cache(fingerprints, opts) do
      {:ok,
       retained
       |> Map.merge(reclaimed)
       |> Map.put(:expiring_bundle_archive_count, expiring_count)
       |> Map.put(:referenced_bundle_count, length(fingerprints))}
    end
  end

  defp retain_referenced_archives(fingerprints) do
    Enum.reduce_while(
      fingerprints,
      {:ok, %{refreshed_bundle_archives: 0, rebuilt_bundle_archives: 0}},
      fn fingerprint, {:ok, result} ->
        case RedisStore.refresh_bundle_archive(fingerprint) do
          :ok ->
            {:cont, {:ok, Map.update!(result, :refreshed_bundle_archives, &(&1 + 1))}}

          {:error, :not_found} ->
            case rebuild_referenced_archive(fingerprint) do
              :ok ->
                {:cont, {:ok, Map.update!(result, :rebuilt_bundle_archives, &(&1 + 1))}}

              {:error, reason} ->
                {:halt, {:error, {:missing_referenced_bundle, fingerprint, reason}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:bundle_archive_refresh_failed, fingerprint, reason}}}
        end
      end
    )
  end

  defp rebuild_referenced_archive(fingerprint) do
    with true <- valid_fingerprint?(fingerprint),
         {:ok, bundle} <- JobBundle.load(cache_path(fingerprint)),
         {:ok, %{fingerprint: ^fingerprint} = archive_ref} <- store(bundle) do
      case RedisStore.refresh_bundle_archive(fingerprint) do
        :ok -> :ok
        {:error, :not_found} when archive_ref.storage != "redis" -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_bundle_fingerprint}
      {:ok, %{fingerprint: other}} -> {:error, {:fingerprint_mismatch, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reclaim_unreferenced_cache(fingerprints, opts) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, cache_ttl_seconds())
    now_seconds = Keyword.get(opts, :now_seconds, System.system_time(:second))
    referenced = MapSet.new(fingerprints)

    case File.ls(cache_root()) do
      {:ok, entries} ->
        candidates =
          entries
          |> Enum.filter(&valid_fingerprint?/1)
          |> Enum.reject(&MapSet.member?(referenced, &1))
          |> Enum.filter(&stale_cache?(&1, ttl_seconds, now_seconds))

        with {:ok, reclaimed} <-
               Enum.reduce_while(candidates, {:ok, []}, fn fingerprint, {:ok, acc} ->
                 case delete_cache(fingerprint) do
                   :ok -> {:cont, {:ok, [fingerprint | acc]}}
                   {:error, reason} -> {:halt, {:error, {fingerprint, reason}}}
                 end
               end) do
          reclaimed = Enum.sort(reclaimed)

          {:ok,
           %{
             reclaimed_bundle_cache_count: length(reclaimed),
             reclaimed_bundle_caches: reclaimed
           }}
        else
          {:error, {fingerprint, reason}} ->
            {:error, {:bundle_cache_delete_failed, fingerprint, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{reclaimed_bundle_cache_count: 0, reclaimed_bundle_caches: []}}

      {:error, reason} ->
        {:error, {:bundle_cache_scan_failed, reason}}
    end
  end

  defp store_with_fingerprint(%JobBundle{} = bundle, fingerprint) do
    case maybe_store_shared_cache(bundle, fingerprint) do
      {:ok, archive_ref} ->
        maybe_store_redis_backup(bundle, fingerprint)
        {:ok, archive_ref}

      :skip ->
        store_redis_archive(bundle, fingerprint)

      {:error, reason} ->
        Logger.warning("failed to cache bundle in shared storage: #{inspect(reason)}")
        store_redis_archive(bundle, fingerprint)
    end
  end

  defp maybe_store_redis_backup(%JobBundle{} = bundle, fingerprint) do
    case store_redis_archive(bundle, fingerprint) do
      {:ok, _archive_ref} ->
        :ok

      {:error, {:bundle_too_large, _total_bytes, _max_bytes}} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to store Redis backup for shared bundle cache: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_store_shared_cache(%JobBundle{} = bundle, fingerprint) do
    if shared_cache_root?() do
      store_filesystem_cache(bundle, fingerprint, "shared_fs_cas")
    else
      :skip
    end
  end

  defp store_filesystem_cache(%JobBundle{root_path: root_path}, fingerprint, storage)
       when is_binary(root_path) do
    with {:ok, _file_specs, total_bytes} <- collect_file_specs(root_path),
         :ok <- copy_local_cache(fingerprint, root_path) do
      {:ok, %{fingerprint: fingerprint, storage: storage, total_bytes: total_bytes}}
    end
  end

  defp store_filesystem_cache(_bundle, _fingerprint, _storage),
    do: {:error, :bundle_has_no_root_path}

  defp store_redis_archive(%JobBundle{} = bundle, fingerprint) do
    case cached_archive(fingerprint) do
      {:ok, archive} ->
        _ = restore_to_cache(fingerprint, archive)

        {:ok,
         %{fingerprint: fingerprint, storage: "redis", total_bytes: archive_total_bytes(archive)}}

      :miss ->
        store_uncached_archive(bundle, fingerprint)
    end
  end

  defp store_uncached_archive(%JobBundle{root_path: root_path} = bundle, fingerprint) do
    with {:ok, file_specs, total_bytes} <- collect_file_specs(root_path),
         :ok <- validate_size(total_bytes),
         {:ok, files} <- read_archive_files(file_specs),
         {:ok, archive} <-
           RedisStore.persist_bundle_archive(fingerprint, %{
             "created_at" => MirrorNeuron.Runtime.timestamp(),
             "graph_id" => bundle.manifest.graph_id,
             "total_bytes" => total_bytes,
             "files" => files
           }) do
      _ = restore_to_cache(fingerprint, archive)
      {:ok, %{fingerprint: fingerprint, storage: "redis", total_bytes: total_bytes}}
    else
      {:error, {:bundle_too_large, total_bytes, max_bytes}} ->
        Logger.warning(
          "bundle #{bundle.manifest.graph_id} is #{total_bytes} bytes, above archive cap #{max_bytes}; cluster recovery will require a shared path or preloaded bundle cache"
        )

        _ = copy_local_cache(fingerprint, root_path)
        {:ok, %{fingerprint: fingerprint, storage: "local_cache", total_bytes: total_bytes}}

      {:error, reason} ->
        Logger.warning("failed to archive bundle for cluster recovery: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp cached_archive(fingerprint) do
    case RedisStore.fetch_bundle_archive(fingerprint) do
      {:ok, archive} -> {:ok, archive}
      {:error, _reason} -> :miss
    end
  end

  defp collect_file_specs(root_path) do
    file_specs =
      root_path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.map(fn path ->
        relative_path = Path.relative_to(path, root_path)
        {:ok, stat} = File.stat(path)

        %{
          "path" => relative_path,
          "bytes" => stat.size,
          "source_path" => path
        }
      end)

    {:ok, file_specs, Enum.sum(Enum.map(file_specs, & &1["bytes"]))}
  rescue
    error -> {:error, error}
  end

  defp read_archive_files(file_specs) do
    files =
      Enum.map(file_specs, fn %{"path" => relative_path, "bytes" => bytes, "source_path" => path} ->
        {:ok, contents} = File.read(path)

        %{
          "path" => relative_path,
          "bytes" => bytes,
          "data" => Base.encode64(contents)
        }
      end)

    {:ok, files}
  rescue
    error -> {:error, error}
  end

  defp archive_total_bytes(%{"total_bytes" => total_bytes}) when is_integer(total_bytes),
    do: total_bytes

  defp archive_total_bytes(%{"files" => files}) when is_list(files) do
    Enum.sum(Enum.map(files, &Map.get(&1, "bytes", 0)))
  end

  defp archive_total_bytes(_archive), do: 0

  defp validate_size(total_bytes) do
    max_bytes = max_archive_bytes()

    if total_bytes <= max_bytes do
      :ok
    else
      {:error, {:bundle_too_large, total_bytes, max_bytes}}
    end
  end

  defp restore_to_cache(fingerprint, %{"files" => files}) when is_list(files) do
    root = cache_path(fingerprint)
    mkdir_shared_cache_dir!(root)
    mkdir_shared_cache_dir!(Path.join(root, "payloads"))

    Enum.each(files, fn %{"path" => relative_path, "data" => encoded} ->
      if PathSafety.safe_relative_path?(relative_path) do
        target = Path.join(root, relative_path)
        mkdir_shared_cache_dir!(Path.dirname(target))
        File.write!(target, Base.decode64!(encoded))
      end
    end)

    :ok
  rescue
    error -> {:error, error}
  end

  defp restore_to_cache(_fingerprint, _archive), do: {:error, :invalid_bundle_archive}

  defp copy_local_cache(fingerprint, root_path) do
    target = cache_path(fingerprint)

    unless valid_bundle_cache?(target) do
      _ = File.rm_rf(target)
      mkdir_shared_cache_dir!(Path.dirname(target))
      File.cp_r(root_path, target)
    end

    chmod_cache_dirs(target)

    :ok
  rescue
    error -> {:error, error}
  end

  defp mkdir_shared_cache_dir!(path) do
    File.mkdir_p!(path)
    chmod_shared_cache_dir(path)
  end

  defp chmod_cache_dirs(root) do
    chmod_shared_cache_dir(root)

    root
    |> File.ls!()
    |> Enum.each(fn entry ->
      path = Path.join(root, entry)

      if File.dir?(path) do
        chmod_cache_dirs(path)
      end
    end)
  end

  defp chmod_shared_cache_dir(path) do
    case File.chmod(path, 0o777) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp valid_bundle_cache?(target) do
    case JobBundle.load(target) do
      {:ok, _bundle} -> true
      {:error, _reason} -> false
    end
  end

  defp touch_cache(fingerprint) do
    marker = access_marker(fingerprint)

    with :ok <- File.mkdir_p(Path.dirname(marker)),
         :ok <- File.touch(marker) do
      :ok
    end
  end

  defp stale_cache?(_fingerprint, ttl_seconds, _now_seconds)
       when not is_integer(ttl_seconds) or ttl_seconds <= 0,
       do: false

  defp stale_cache?(fingerprint, ttl_seconds, now_seconds) do
    path = cache_path(fingerprint)

    if File.dir?(path) do
      case cache_last_used_at(fingerprint) do
        {:ok, last_used_at} -> now_seconds - last_used_at >= ttl_seconds
        {:error, _reason} -> false
      end
    else
      false
    end
  end

  defp cache_last_used_at(fingerprint) do
    case File.stat(access_marker(fingerprint), time: :posix) do
      {:ok, stat} -> {:ok, stat.mtime}
      {:error, :enoent} -> cache_directory_mtime(fingerprint)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cache_directory_mtime(fingerprint) do
    case File.stat(cache_path(fingerprint), time: :posix) do
      {:ok, stat} -> {:ok, stat.mtime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_cache(fingerprint) do
    case File.rm_rf(cache_path(fingerprint)) do
      {:ok, _removed} ->
        _ = File.rm(access_marker(fingerprint))
        :ok

      {:error, reason, _path} ->
        {:error, reason}
    end
  end

  defp access_marker(fingerprint), do: Path.join([cache_root(), ".access", fingerprint])

  defp valid_fingerprint?(fingerprint) when is_binary(fingerprint),
    do: Regex.match?(@fingerprint_pattern, fingerprint)

  defp valid_fingerprint?(_fingerprint), do: false

  defp cache_root do
    MirrorNeuron.Config.optional_string("MN_BUNDLE_CACHE_DIR", :bundle_cache_dir) ||
      Path.join(SharedStorage.root(), "bundle_cache")
  rescue
    _ ->
      Path.join(MirrorNeuron.Config.string("MN_TEMP_DIR", :temp_dir), "bundle_cache")
  end

  defp shared_cache_root? do
    cache_root = Path.expand(cache_root())
    shared_root = Path.expand(SharedStorage.root())

    cache_root == shared_root or String.starts_with?(cache_root, shared_root <> "/")
  rescue
    _ -> false
  end

  defp max_archive_bytes do
    MirrorNeuron.Config.integer("MN_BUNDLE_ARCHIVE_MAX_BYTES", :bundle_archive_max_bytes)
  rescue
    _ -> @default_max_bytes
  end

  defp cache_ttl_seconds do
    MirrorNeuron.Config.integer(
      "MN_BUNDLE_ARCHIVE_TTL_SECONDS",
      :bundle_archive_ttl_seconds
    )
  rescue
    _ -> @default_cache_ttl_seconds
  end
end
