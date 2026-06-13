defmodule MirrorNeuron.Bundle.Archive do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Bundle.Fingerprint
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore

  @default_max_bytes 50 * 1024 * 1024

  def store(%JobBundle{root_path: root_path} = bundle) when is_binary(root_path) do
    case Fingerprint.compute(root_path) do
      {:ok, fingerprint} ->
        store_with_fingerprint(bundle, fingerprint)

      {:error, reason} ->
        Logger.warning("failed to archive bundle for cluster recovery: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def store(_bundle), do: {:error, :bundle_has_no_root_path}

  def load(fingerprint) when is_binary(fingerprint) and fingerprint != "" do
    cache_path = cache_path(fingerprint)

    case JobBundle.load(cache_path) do
      {:ok, bundle} ->
        {:ok, bundle}

      {:error, _cache_reason} ->
        with {:ok, archive} <- RedisStore.fetch_bundle_archive(fingerprint),
             :ok <- restore_to_cache(fingerprint, archive),
             {:ok, bundle} <- JobBundle.load(cache_path) do
          {:ok, bundle}
        end
    end
  end

  def load(_fingerprint), do: {:error, :missing_bundle_fingerprint}

  def cache_path(fingerprint), do: Path.join(cache_root(), fingerprint)

  defp store_with_fingerprint(%JobBundle{} = bundle, fingerprint) do
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
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "payloads"))

    Enum.each(files, fn %{"path" => relative_path, "data" => encoded} ->
      if safe_relative_path?(relative_path) do
        target = Path.join(root, relative_path)
        File.mkdir_p!(Path.dirname(target))
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

    unless File.dir?(target) do
      File.mkdir_p!(Path.dirname(target))
      File.cp_r(root_path, target)
    end

    :ok
  rescue
    error -> {:error, error}
  end

  defp safe_relative_path?(path) when is_binary(path) do
    path = String.replace(path, "\\", "/")

    Path.type(path) == :relative and
      path not in ["", "."] and
      path
      |> String.split("/", trim: true)
      |> Enum.all?(&(&1 not in [".", ".."]))
  end

  defp safe_relative_path?(_path), do: false

  defp cache_root do
    System.get_env("MN_BUNDLE_CACHE_DIR") ||
      Application.get_env(:mirror_neuron, :bundle_cache_dir) ||
      Path.join(MirrorNeuron.Config.string("MN_TEMP_DIR", :temp_dir), "bundle_cache")
  end

  defp max_archive_bytes do
    case System.get_env("MN_BUNDLE_ARCHIVE_MAX_BYTES") do
      nil -> Application.get_env(:mirror_neuron, :bundle_archive_max_bytes, @default_max_bytes)
      "" -> Application.get_env(:mirror_neuron, :bundle_archive_max_bytes, @default_max_bytes)
      value -> parse_positive_integer(value, @default_max_bytes)
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end
end
