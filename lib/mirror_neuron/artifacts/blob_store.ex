defmodule MirrorNeuron.Artifacts.BlobStore do
  @moduledoc false

  @chunk_size 1_048_576
  @sha256_re ~r/^[a-f0-9]{64}$/

  def root do
    MirrorNeuron.Config.string("MN_BLOB_STORE_ROOT", :blob_store_root)
  end

  def path(sha256) when is_binary(sha256) do
    sha256 = String.downcase(sha256)

    if Regex.match?(@sha256_re, sha256) do
      Path.join([root(), binary_part(sha256, 0, 2), sha256])
    else
      nil
    end
  end

  def path(_sha256), do: nil

  def relative_path(sha256) when is_binary(sha256) do
    sha256 = String.downcase(sha256)

    if Regex.match?(@sha256_re, sha256) do
      Path.join(binary_part(sha256, 0, 2), sha256)
    end
  end

  def relative_path(_sha256), do: nil

  def has?(sha256) do
    case path(sha256) do
      nil -> false
      blob_path -> File.regular?(blob_path)
    end
  end

  def valid?(sha256) do
    with blob_path when is_binary(blob_path) <- path(sha256),
         true <- File.regular?(blob_path),
         {:ok, ^sha256} <- sha256_file(blob_path) do
      true
    else
      _ -> false
    end
  end

  def put_file(source_path, expected_sha256 \\ nil) do
    with true <- File.regular?(source_path),
         {:ok, sha256} <- sha256_file(source_path),
         :ok <- validate_expected_sha(expected_sha256, sha256),
         {:ok, target_path} <- target_path(sha256) do
      if File.regular?(target_path) and valid?(sha256) do
        {:ok, %{sha256: sha256, path: target_path, bytes: file_size(target_path)}}
      else
        tmp_path = target_path <> ".tmp-#{System.unique_integer([:positive])}"
        File.mkdir_p!(Path.dirname(target_path))

        with :ok <- File.cp(source_path, tmp_path),
             true <- valid_file?(tmp_path, sha256),
             :ok <- File.rename(tmp_path, target_path) do
          {:ok, %{sha256: sha256, path: target_path, bytes: file_size(target_path)}}
        else
          false ->
            _ = File.rm(tmp_path)
            {:error, "blob hash verification failed for #{source_path}"}

          {:error, reason} ->
            _ = File.rm(tmp_path)
            {:error, reason}
        end
      end
    else
      false -> {:error, "blob source file does not exist: #{source_path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_bytes(bytes, expected_sha256 \\ nil) when is_binary(bytes) do
    sha256 = sha256_bytes(bytes)

    with :ok <- validate_expected_sha(expected_sha256, sha256),
         {:ok, target_path} <- target_path(sha256) do
      if File.regular?(target_path) and valid?(sha256) do
        {:ok, %{sha256: sha256, path: target_path, bytes: file_size(target_path)}}
      else
        tmp_path = target_path <> ".tmp-#{System.unique_integer([:positive])}"
        File.mkdir_p!(Path.dirname(target_path))

        with :ok <- File.write(tmp_path, bytes),
             true <- valid_file?(tmp_path, sha256),
             :ok <- File.rename(tmp_path, target_path) do
          {:ok, %{sha256: sha256, path: target_path, bytes: byte_size(bytes)}}
        else
          false ->
            _ = File.rm(tmp_path)
            {:error, "blob hash verification failed for bytes"}

          {:error, reason} ->
            _ = File.rm(tmp_path)
            {:error, reason}
        end
      end
    end
  end

  def materialize_file(source, destination) when is_binary(source) and is_binary(destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)

    cond do
      source == destination ->
        :ok

      not File.regular?(source) ->
        {:error, "blob source file does not exist: #{source}"}

      true ->
        do_materialize_file(source, destination)
    end
  end

  def sha256_file(path) do
    context = :crypto.hash_init(:sha256)

    digest =
      path
      |> File.stream!([], @chunk_size)
      |> Enum.reduce(context, fn chunk, acc -> :crypto.hash_update(acc, chunk) end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def sha256_bytes(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp target_path(sha256) do
    case path(sha256) do
      nil -> {:error, "invalid blob sha256 #{inspect(sha256)}"}
      blob_path -> {:ok, blob_path}
    end
  end

  defp do_materialize_file(source, destination) do
    tmp_path = destination <> ".tmp-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(destination))

    result =
      case File.ln(source, tmp_path) do
        :ok -> :ok
        {:error, _reason} -> File.cp(source, tmp_path)
      end

    case result do
      :ok ->
        case File.rename(tmp_path, destination) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(tmp_path)
            {:error, "failed to materialize blob #{source} to #{destination}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, "failed to materialize blob #{source} to #{destination}: #{inspect(reason)}"}
    end
  end

  defp validate_expected_sha(nil, _sha256), do: :ok
  defp validate_expected_sha("", _sha256), do: :ok

  defp validate_expected_sha(expected, sha256) do
    if String.downcase(to_string(expected)) == sha256 do
      :ok
    else
      {:error, "blob hash mismatch: expected #{expected}, got #{sha256}"}
    end
  end

  defp valid_file?(path, sha256) do
    case sha256_file(path) do
      {:ok, ^sha256} -> true
      _ -> false
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> nil
    end
  end
end
