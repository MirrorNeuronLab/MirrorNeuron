defmodule MirrorNeuron.Backup.Files do
  @moduledoc false
  alias MirrorNeuron.Artifacts.BlobStore
  alias Mirrorneuron.Job.V1.JobBackupChunk

  @chunk_bytes 1_048_576
  @max_bytes 137_438_953_472
  @max_files 100_000

  def safe_path!(root, name) do
    parts = String.split(name, "/")

    if name == "" or String.contains?(name, ["\\", ":", <<0>>]) or
         Enum.any?(parts, &(&1 in ["", ".", ".."])) do
      raise ArgumentError, "invalid backup path"
    end

    Path.join(root, name)
  end

  def tree(root, prefix) do
    case File.lstat(root) do
      {:error, :enoent} ->
        []

      {:ok, %{type: :directory, mode: mode}} ->
        [{prefix, root, true, Bitwise.band(mode, 0o777)} | walk(root, prefix)]

      _ ->
        raise ArgumentError, "backup source must be a directory without symlinks"
    end
  end

  defp walk(root, prefix) do
    File.ls!(root)
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = safe_path!(root, name)
      relative = prefix <> "/" <> name

      case File.lstat!(path) do
        %{type: :directory, mode: mode} ->
          [{relative, path, true, Bitwise.band(mode, 0o777)} | walk(path, relative)]

        %{type: :regular, mode: mode} ->
          [{relative, path, false, Bitwise.band(mode, 0o777)}]

        _ ->
          raise ArgumentError, "backup cannot contain symlinks or special files"
      end
    end)
  end

  def inventory(entries) do
    entries = complete(entries)
    if length(entries) > @max_files, do: raise(ArgumentError, "too many backup files")

    result =
      Map.new(entries, fn {name, path, directory, mode} ->
        size = if directory, do: 0, else: File.stat!(path).size
        hash = if directory, do: nil, else: elem(BlobStore.sha256_file(path), 1)
        {name, %{"directory" => directory, "mode" => mode, "size" => size, "sha256" => hash}}
      end)

    if Enum.sum(Enum.map(result, fn {_, item} -> item["size"] end)) > @max_bytes,
      do: raise(ArgumentError, "backup exceeds 128 GiB")

    result
  end

  def chunks(entries) do
    Stream.flat_map(complete(entries), fn {name, path, directory, mode} ->
      ending = %JobBackupChunk{
        path: name,
        eof: true,
        directory: directory,
        mode: mode,
        version: 1
      }

      if directory do
        [ending]
      else
        Stream.concat(
          Stream.map(File.stream!(path, @chunk_bytes, []), fn data ->
            %JobBackupChunk{path: name, data: data, version: 1}
          end),
          [ending]
        )
      end
    end)
  end

  defp complete(entries) do
    parents =
      Enum.flat_map(entries, fn {name, _, _, _} ->
        name
        |> Path.split()
        |> Enum.drop(-1)
        |> Enum.scan(fn name, path -> Path.join(path, name) end)
        |> Enum.map(&{&1, nil, true, 0o755})
      end)

    (entries ++ parents) |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0))
  end

  # Receiver writes only inside a fresh private directory. It accepts ordered
  # files, rejects repeated/case-colliding names, and bounds both disk and RAM.
  def receive!(chunks, root) do
    final =
      Enum.reduce(chunks, %{current: nil, seen: MapSet.new(), bytes: 0}, fn chunk, state ->
        if chunk.version != 1 or byte_size(chunk.data) > @chunk_bytes,
          do: raise(ArgumentError, "invalid backup chunk")

        destination = safe_path!(root, chunk.path)
        key = String.downcase(chunk.path)
        bytes = state.bytes + byte_size(chunk.data)
        if bytes > @max_bytes, do: raise(ArgumentError, "backup exceeds 128 GiB")

        if state.current not in [nil, chunk.path],
          do: raise(ArgumentError, "interleaved backup files")

        seen =
          if is_nil(state.current) do
            if MapSet.member?(state.seen, key) or MapSet.size(state.seen) >= @max_files,
              do: raise(ArgumentError, "duplicate or excessive backup paths")

            File.mkdir_p!(Path.dirname(destination))

            if chunk.directory do
              if not chunk.eof or chunk.data != "",
                do: raise(ArgumentError, "invalid directory chunk")

              File.mkdir_p!(destination)
            else
              File.write!(destination, "", [:exclusive])
            end

            MapSet.put(state.seen, key)
          else
            state.seen
          end

        if chunk.data != "", do: File.write!(destination, chunk.data, [:append])
        if chunk.eof, do: File.chmod!(destination, Bitwise.band(chunk.mode, 0o777))
        %{current: if(chunk.eof, do: nil, else: chunk.path), seen: seen, bytes: bytes}
      end)

    if final.current, do: raise(ArgumentError, "incomplete backup stream")
    :ok
  end

  def verify!(root, inventory) when is_map(inventory) do
    actual =
      tree(root, "snapshot")
      |> Enum.map(fn {name, path, directory, mode} ->
        {String.replace_prefix(name, "snapshot/", ""), path, directory, mode}
      end)
      |> Enum.reject(fn {name, _, _, _} ->
        name in ["snapshot", "mn-backup.json", "restore.json"]
      end)
      |> inventory()

    if actual != inventory, do: raise(ArgumentError, "backup inventory or checksum mismatch")
    :ok
  end
end
