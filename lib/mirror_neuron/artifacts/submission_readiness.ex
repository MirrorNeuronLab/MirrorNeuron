defmodule MirrorNeuron.Artifacts.SubmissionReadiness do
  @moduledoc false

  alias MirrorNeuron.Artifacts.SharedStorage

  @version "mn.input_readiness/v1"
  @default_timeout_seconds 1_800
  @poll_interval_ms 1_000
  @event_interval_ms 5_000

  @doc """
  Verifies the owner-local copy of a staged submission input tree.

  The SDK atomically publishes an inventory marker only after it has copied all
  selected local inputs.  A missing or temporarily inconsistent marker is a
  normal Syncthing replication state and is therefore retryable.  Malformed
  paths are rejected immediately rather than being used to read outside the
  shared-storage mount.
  """
  def verify(manifest) do
    case readiness_descriptor(manifest) do
      :none ->
        {:ready, %{"managed" => false}}

      {:ok, storage, descriptor} ->
        base_metrics = descriptor_metrics(descriptor)

        with :ok <- validate_descriptor(descriptor),
             {:ok, submission_root} <- submission_root(storage),
             {:ok, marker_path} <- resolve_relative(submission_root, map_get(descriptor, "path")),
             {:ok, marker} <- read_verified_marker(marker_path, descriptor),
             {:ok, entries} <- inventory_entries(marker) do
          verify_entries(Path.join(submission_root, "inputs"), entries)
        else
          {:waiting, reason} -> {:waiting, Map.put(base_metrics, "reason", reason)}
          {:error, reason} -> {:error, reason, base_metrics}
        end
    end
  end

  def timeout_seconds do
    case MirrorNeuron.Config.integer(
           "MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS",
           :shared_storage_ready_timeout_seconds
         ) do
      value when value >= 0 -> value
      _negative -> @default_timeout_seconds
    end
  end

  def poll_interval_ms, do: @poll_interval_ms
  def event_interval_ms, do: @event_interval_ms

  defp readiness_descriptor(manifest) do
    metadata = map_get(manifest, "metadata")
    storage = map_get(metadata, "mn_storage")
    inputs = map_get(storage, "inputs")
    descriptor = map_get(inputs, "readiness")

    if is_map(storage) and is_map(descriptor), do: {:ok, storage, descriptor}, else: :none
  end

  defp validate_descriptor(descriptor) do
    with true <- map_get(descriptor, "version") == @version,
         true <- safe_relative?(map_get(descriptor, "path")),
         true <- valid_sha256?(map_get(descriptor, "sha256")),
         true <- nonnegative_integer?(map_get(descriptor, "size_bytes")),
         true <- nonnegative_integer?(map_get(descriptor, "file_count")),
         true <- nonnegative_integer?(map_get(descriptor, "total_bytes")) do
      :ok
    else
      false -> {:error, "invalid_submission_readiness_descriptor"}
    end
  end

  defp submission_root(storage) do
    submission_id = map_get(storage, "submission_id")
    root = Path.expand(SharedStorage.root())

    if safe_submission_id?(submission_id) do
      {:ok, Path.join([root, "submissions", submission_id])}
    else
      {:error, "submission_readiness_submission_id_missing"}
    end
  end

  defp read_verified_marker(path, descriptor) do
    case File.read(path) do
      {:ok, contents} ->
        expected_size = map_get(descriptor, "size_bytes")
        expected_hash = map_get(descriptor, "sha256")

        cond do
          byte_size(contents) != expected_size ->
            {:waiting, "readiness_manifest_size_mismatch"}

          sha256(contents) != expected_hash ->
            {:waiting, "readiness_manifest_digest_mismatch"}

          true ->
            case Jason.decode(contents) do
              {:ok, marker} when is_map(marker) -> {:ok, marker}
              _ -> {:waiting, "readiness_manifest_invalid_json"}
            end
        end

      {:error, :enoent} ->
        {:waiting, "readiness_manifest_missing"}

      {:error, reason} ->
        {:waiting, "readiness_manifest_unavailable:#{reason}"}
    end
  end

  defp inventory_entries(marker) do
    files = map_get(marker, "files")

    with true <- map_get(marker, "version") == @version,
         true <- is_list(files),
         true <- map_get(marker, "file_count") == length(files),
         {:ok, entries} <- normalize_entries(files),
         true <- map_get(marker, "total_bytes") == Enum.sum(Enum.map(entries, &elem(&1, 1))) do
      {:ok, entries}
    else
      false -> {:error, "invalid_submission_readiness_manifest"}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_entries(files) do
    Enum.reduce_while(files, {:ok, {[], MapSet.new()}}, fn entry, {:ok, {items, seen}} ->
      path = map_get(entry, "path")
      size = map_get(entry, "size_bytes")
      digest = map_get(entry, "sha256")

      if is_map(entry) and safe_relative?(path) and nonnegative_integer?(size) and
           valid_sha256?(digest) and not MapSet.member?(seen, path) do
        {:cont, {:ok, {[{path, size, digest} | items], MapSet.put(seen, path)}}}
      else
        {:halt, {:error, "invalid_submission_readiness_entry"}}
      end
    end)
    |> case do
      {:ok, {items, _seen}} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp verify_entries(inputs_root, entries) do
    {remaining_files, remaining_bytes, reason} =
      Enum.reduce(entries, {0, 0, nil}, fn {relative, expected_size, expected_hash},
                                           {file_count, byte_count, first_reason} ->
        target = Path.join(inputs_root, relative)

        if valid_file?(target, expected_size, expected_hash) do
          {file_count, byte_count, first_reason}
        else
          {file_count + 1, byte_count + expected_size, first_reason || "input_file_pending"}
        end
      end)

    metrics = %{
      "managed" => true,
      "total_files" => length(entries),
      "total_bytes" => Enum.sum(Enum.map(entries, &elem(&1, 1))),
      "remaining_files" => remaining_files,
      "remaining_bytes" => remaining_bytes
    }

    if remaining_files == 0,
      do: {:ready, metrics},
      else: {:waiting, Map.put(metrics, "reason", reason)}
  end

  defp valid_file?(path, expected_size, expected_hash) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: ^expected_size}} ->
        case sha256_file(path) do
          {:ok, ^expected_hash} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp sha256_file(path) do
    digest =
      path
      |> File.stream!(1_048_576, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
        :crypto.hash_update(context, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    File.Error -> {:error, :unavailable}
  end

  defp descriptor_metrics(descriptor) do
    %{
      "managed" => true,
      "total_files" => map_get(descriptor, "file_count") || 0,
      "total_bytes" => map_get(descriptor, "total_bytes") || 0,
      "remaining_files" => map_get(descriptor, "file_count") || 0,
      "remaining_bytes" => map_get(descriptor, "total_bytes") || 0
    }
  end

  defp resolve_relative(root, path) do
    if safe_relative?(path) do
      expanded = Path.expand(Path.join(root, path))

      if inside_root?(expanded, root),
        do: {:ok, expanded},
        else: {:error, "unsafe_readiness_path"}
    else
      {:error, "unsafe_readiness_path"}
    end
  end

  defp safe_relative?(path) when is_binary(path) do
    relative = Path.relative_to(path, ".")

    path != "" and Path.type(path) == :relative and relative == path and
      path
      |> Path.split()
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp safe_relative?(_path), do: false

  defp safe_submission_id?(value) when is_binary(value) do
    value != "" and Path.type(value) == :relative and Path.basename(value) == value and
      value not in [".", ".."] and not String.contains?(value, "\\")
  end

  defp safe_submission_id?(_value), do: false

  defp inside_root?(path, root) do
    relative = Path.relative_to(path, root)
    relative != ".." and not String.starts_with?(relative, "../")
  end

  defp valid_sha256?(value) when is_binary(value), do: value =~ ~r/\A[0-9a-f]{64}\z/
  defp valid_sha256?(_value), do: false

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil
end
