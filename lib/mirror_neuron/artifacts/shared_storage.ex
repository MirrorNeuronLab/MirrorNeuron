defmodule MirrorNeuron.Artifacts.SharedStorage do
  @moduledoc false

  require Logger

  @metadata_key "mn_storage"
  @terminal_statuses ["completed", "failed", "cancelled"]
  @atom_keys %{
    "metadata" => :metadata,
    "mn_storage" => :mn_storage,
    "output_copy" => :output_copy,
    "source_path" => :source_path,
    "source" => :source,
    "target_path" => :target_path,
    "target" => :target,
    "output_copy_executor" => :output_copy_executor,
    "submission_path" => :submission_path
  }

  def root do
    MirrorNeuron.Config.optional_string(
      "MN_RUNTIME_SHARED_STORAGE_ROOT",
      :runtime_shared_storage_root
    ) ||
      MirrorNeuron.Config.string("MN_SHARED_STORAGE_ROOT", :shared_storage_root)
  end

  def validate! do
    root = Path.expand(root())

    with :ok <- File.mkdir_p(root),
         true <- File.dir?(root),
         :ok <- ensure_writable(root) do
      :ok
    else
      false ->
        raise ArgumentError, "MN_SHARED_STORAGE_ROOT must be a directory: #{root}"

      {:error, reason} ->
        raise ArgumentError,
              "MN_SHARED_STORAGE_ROOT must be writable at #{root}: #{inspect(reason)}"
    end
  end

  def finalize_terminal_job(job_id, manifest, status) when status in @terminal_statuses do
    case storage_metadata(manifest) do
      nil ->
        {:ok, []}

      storage ->
        if master_host_output_copy?(storage) do
          {:ok, []}
        else
          finalize_runtime_output_copy(job_id, storage, status)
        end
    end
  end

  def finalize_terminal_job(_job_id, _manifest, _status), do: {:ok, []}

  defp finalize_runtime_output_copy(job_id, storage, status) do
    warnings = copy_outputs(storage, status)
    fatal? = Enum.any?(warnings, &fatal_warning?/1)

    if fatal? do
      Logger.warning(
        "shared storage output finalization for #{job_id} completed with warnings: #{inspect(warnings)}"
      )

      {:error, warnings}
    else
      {:ok, warnings}
    end
  end

  def cleanup_job(job_id, job_map) do
    case job_manifest(job_map) do
      nil ->
        :ok

      manifest ->
        cleanup_manifest(job_id, manifest)
    end
  end

  def cleanup_manifest(job_id, manifest) do
    case storage_metadata(manifest) do
      nil -> :ok
      storage -> cleanup_storage(storage, job_id)
    end
  end

  defp copy_outputs(storage, status) do
    storage
    |> map_get("output_copy")
    |> list_value()
    |> Enum.flat_map(&copy_output_spec(&1, status))
  end

  defp copy_output_spec(spec, status) when is_map(spec) do
    source = first_string(map_get(spec, "source_path"), map_get(spec, "source"))
    target = first_string(map_get(spec, "target_path"), map_get(spec, "target"))

    cond do
      is_nil(source) or is_nil(target) ->
        [
          warning(
            "invalid_output_copy",
            "output copy spec requires source_path and target_path",
            true
          )
        ]

      not File.exists?(source) ->
        [
          warning(
            "missing_output_source",
            "output source does not exist: #{source}",
            status not in ["cancelled"]
          )
        ]

      true ->
        case copy_output_path(source, target) do
          :ok ->
            []

          {:error, reason} ->
            [
              warning(
                "output_copy_failed",
                "failed to copy #{source} to #{target}: #{reason}",
                true
              )
            ]
        end
    end
  end

  defp copy_output_spec(_spec, _status) do
    [warning("invalid_output_copy", "output copy spec must be an object", true)]
  end

  defp copy_output_path(source, target) do
    source = Path.expand(source)
    target = Path.expand(target)

    cond do
      File.dir?(source) ->
        copy_directory_contents(source, target)

      File.regular?(source) ->
        copy_file(source, Path.join(target, Path.basename(source)))

      true ->
        {:error, "source is not a regular file or directory"}
    end
  end

  defp copy_directory_contents(source, target) do
    with :ok <- File.mkdir_p(target),
         {:ok, entries} <- File.ls(source) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case copy_path(Path.join(source, entry), Path.join(target, entry)) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp copy_path(source, target) do
    cond do
      File.dir?(source) ->
        with :ok <- File.mkdir_p(target),
             {:ok, entries} <- File.ls(source) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case copy_path(Path.join(source, entry), Path.join(target, entry)) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        else
          {:error, reason} -> {:error, inspect(reason)}
        end

      File.regular?(source) ->
        copy_file(source, target)

      true ->
        :ok
    end
  end

  defp copy_file(source, target) do
    case File.mkdir_p(Path.dirname(target)) do
      :ok ->
        case File.cp(source, target) do
          :ok -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp cleanup_storage(storage, job_id) do
    case safe_submission_path(storage) do
      {:ok, path} ->
        case File.rm_rf(path) do
          {:ok, _files} ->
            :ok

          {:error, reason, file} ->
            Logger.warning(
              "failed to clean shared submission storage for #{job_id} at #{file}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("skipping shared storage cleanup for #{job_id}: #{reason}")
        {:error, reason}
    end
  end

  defp safe_submission_path(storage) do
    with path when is_binary(path) and path != "" <- map_get(storage, "submission_path"),
         root <- Path.expand(root()),
         expanded <- Path.expand(path),
         true <- inside_root?(expanded, root),
         true <- Path.basename(Path.dirname(expanded)) == "submissions" do
      {:ok, expanded}
    else
      nil -> {:error, "mn_storage.submission_path is missing"}
      "" -> {:error, "mn_storage.submission_path is empty"}
      false -> {:error, "mn_storage.submission_path is outside shared storage root"}
      _ -> {:error, "mn_storage.submission_path is invalid"}
    end
  end

  defp storage_metadata(%{metadata: metadata}), do: storage_metadata(%{"metadata" => metadata})

  defp storage_metadata(%{"metadata" => metadata}) when is_map(metadata) do
    metadata
    |> map_get(@metadata_key)
    |> case do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp storage_metadata(manifest) when is_map(manifest) do
    manifest
    |> map_get("metadata")
    |> case do
      value when is_map(value) -> storage_metadata(%{"metadata" => value})
      _ -> nil
    end
  end

  defp storage_metadata(_manifest), do: nil

  defp job_manifest(%{"manifest" => manifest}) when is_map(manifest), do: manifest
  defp job_manifest(%{manifest: manifest}) when is_map(manifest), do: manifest
  defp job_manifest(_job_map), do: nil

  defp warning(code, message, fatal) do
    %{"code" => code, "message" => message, "fatal" => fatal}
  end

  defp fatal_warning?(%{"fatal" => true}), do: true
  defp fatal_warning?(_warning), do: false

  defp map_get(map, key) when is_map(map) do
    atom_key = Map.get(@atom_keys, key)
    Map.get(map, key) || (atom_key && Map.get(map, atom_key))
  end

  defp map_get(_map, _key), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp first_string(first, second) do
    Enum.find_value([first, second], fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end)
  end

  defp master_host_output_copy?(storage) do
    first_string(map_get(storage, "output_copy_executor"), nil) == "master_host"
  end

  defp ensure_writable(root) do
    probe = Path.join(root, ".mn-shared-storage-#{System.unique_integer([:positive])}")

    case File.write(probe, "ok") do
      :ok ->
        File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
