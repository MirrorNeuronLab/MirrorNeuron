defmodule MirrorNeuron.Sandbox.WitArtifacts do
  @moduledoc "Hash-verified, create-only writes using the existing committed run artifact format."
  alias MirrorNeuron.Sandbox.WasmtimePayload
  @max 16 * 1024 * 1024
  def digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  def read(root, name, hash) do
    with {:ok, path} <- safe_path(root, name, false),
         {:ok, %{type: :regular, size: size}} when size <= @max <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <-
           byte_size(bytes) <= @max and String.valid?(bytes) and
             (is_nil(hash) or hash == digest(bytes)) do
      {:ok, bytes}
    else
      {:error, :enoent} -> {:error, :artifact_missing}
      _ -> {:error, :artifact_integrity_error}
    end
  end

  def commit(root, name, kind, content)
      when is_binary(kind) and byte_size(kind) in 1..64 and is_binary(content) and
             byte_size(content) <= @max do
    with true <- kind != "json" or match?({:ok, _}, Jason.decode(content)),
         {:ok, target} <- safe_path(root, name, true) do
      temp =
        Path.join(
          Path.dirname(target),
          ".wit-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        )

      try do
        with {:ok, :ok} <-
               File.open(temp, [:exclusive, :write, :binary, :sync], fn f ->
                 IO.binwrite(f, content)
               end),
             :ok <- File.chmod(temp, 0o644),
             :ok <- install(temp, target, root, name, content) do
          {:ok,
           %{
             "type" => "artifact_ref",
             "version" =>
               if(kind == "json", do: "mn.committed_json/v1", else: "mn.committed_bytes/v1"),
             "kind" => kind,
             "path" => name,
             "size_bytes" => byte_size(content),
             "sha256" => digest(content)
           }}
        end
      after
        File.rm(temp)
      end
    else
      _ -> {:error, :invalid_artifact}
    end
  end

  def commit(_, _, _, _), do: {:error, :invalid_artifact}

  defp install(temp, target, root, name, content) do
    case File.ln(temp, target) do
      {:error, :eexist} ->
        case read(root, name, digest(content)) do
          {:ok, ^content} -> :ok
          _ -> {:error, :artifact_conflict}
        end

      other ->
        other
    end
  end

  # All parents below the trusted mount must be real directories, including
  # existing parents on retries. Internal handoff and locking files are private.
  def directory(root, parts, create) do
    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, dir} ->
      path = Path.join(dir, part)
      if create, do: File.mkdir(path)

      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          {:cont, {:ok, path}}

        other ->
          {:halt,
           if(other == {:error, :enoent}, do: other, else: {:error, :invalid_artifact_directory})}
      end
    end)
  end

  defp safe_path(root, name, create) do
    if WasmtimePayload.relative?(name) and byte_size(name) <= 1024 and
         Enum.all?(Path.split(name), &(not String.starts_with?(&1, ".") or &1 == ".github")) and
         not String.starts_with?(name, ".") do
      with {:ok, dir} <- directory(root, Enum.drop(Path.split(name), -1), create),
           do: {:ok, Path.join(dir, Path.basename(name))}
    else
      {:error, :invalid_artifact_path}
    end
  end

  def static_report(root, path, hash, title)
      when is_binary(title) and byte_size(title) in 1..300 do
    with true <- is_binary(hash) and is_binary(path) and Path.extname(path) in [".html", ".htm"],
         {:ok, contents} <- read(root, path, hash),
         true <-
           String.contains?(
             String.downcase(binary_part(contents, 0, min(4096, byte_size(contents)))),
             "<html"
           ) do
      absolute = Path.expand(path, root)
      url = "file://" <> URI.encode(absolute, fn c -> c == ?/ or URI.char_unreserved?(c) end)

      {:ok,
       %{
         "kind" => "output",
         "adapter" => "static_html",
         "path" => absolute,
         "url" => url,
         "title" => title,
         "metadata" => %{
           "renderer" => "static_html",
           "optional" => true,
           "sha256" => hash,
           "size_bytes" => byte_size(contents)
         }
       }}
    else
      _ -> {:error, :invalid_static_report}
    end
  end

  def static_report(_, _, _, _), do: {:error, :invalid_static_report}
end
