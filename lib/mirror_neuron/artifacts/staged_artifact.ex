defmodule MirrorNeuron.Artifacts.StagedArtifact.NotReadyError do
  defexception [:message, code: "artifact_not_ready", retryable: true]
end

defmodule MirrorNeuron.Artifacts.StagedArtifact.IntegrityError do
  defexception [:message]
end

defmodule MirrorNeuron.Artifacts.StagedArtifact do
  @moduledoc false

  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Artifacts.StagedArtifact.{IntegrityError, NotReadyError}

  @version "mn.staged_artifact/v1"
  @storage "syncthing"
  @output_key "_mn_staged_artifact"
  @default_timeout_ms 30_000
  @default_inline_bytes 1_048_576

  def version, do: @version
  def output_key, do: @output_key

  def inline_value?(value) do
    value
    |> Jason.encode!()
    |> byte_size()
    |> Kernel.<=(inline_payload_max_bytes())
  end

  def ref?(value) when is_map(value) do
    Map.get(value, "version") == @version and
      Map.get(value, "storage") == @storage and
      is_binary(Map.get(value, "submission_id")) and
      is_binary(Map.get(value, "relative_path")) and
      is_binary(Map.get(value, "sha256")) and
      is_integer(Map.get(value, "size_bytes"))
  end

  def ref?(_value), do: false

  def output_ref(%{@output_key => reference} = value)
      when map_size(value) == 1 and is_map(reference) do
    if ref?(reference), do: reference, else: nil
  end

  def output_ref(_value), do: nil

  def maybe_stage_output(payload, opts \\ []) when is_map(payload) do
    encoded = Jason.encode!(payload)

    if byte_size(encoded) > inline_payload_max_bytes() do
      with {:ok, reference} <- stage_encoded(encoded, opts) do
        {:ok, %{@output_key => reference}, reference}
      end
    else
      {:ok, payload, nil}
    end
  end

  def stage(value, opts \\ []) do
    stage_encoded(Jason.encode!(value), opts)
  end

  def stage_from_manifest(value, manifest, opts \\ []) do
    storage = storage_metadata(manifest)

    stage(
      value,
      Keyword.merge(
        [
          submission_id: map_get(storage, "submission_id"),
          submission_path: map_get(storage, "submission_path")
        ],
        opts
      )
    )
  end

  def resolve_output!(value, opts \\ []) do
    case output_ref(value) do
      nil -> value
      reference -> resolve!(reference, opts)
    end
  end

  def resolve!(reference, opts \\ []) do
    unless ref?(reference), do: raise(ArgumentError, "invalid staged artifact reference")

    timeout_ms = Keyword.get(opts, :timeout_ms, resolve_timeout_ms())
    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
    resolve_until!(reference, candidate_paths(reference, opts), deadline)
  end

  def resolve_pointer!(path, opts \\ []) when is_binary(path) do
    timeout_ms = Keyword.get(opts, :timeout_ms, resolve_timeout_ms())
    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
    resolve_pointer_until!(Path.expand(path), opts, deadline)
  end

  defp stage_encoded(encoded, opts) do
    with {:ok, submission_path} <- submission_path(opts),
         submission_id when is_binary(submission_id) and submission_id != "" <-
           Keyword.get(opts, :submission_id) || Path.basename(submission_path) do
      run_id =
        opts
        |> Keyword.get(:run_id, "run")
        |> to_string()
        |> nonempty("run")

      kind = opts |> Keyword.get(:kind, "json") |> to_string()
      digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
      safe_run_id = safe_component(run_id)

      relative_path =
        Path.join([
          "outputs",
          "runs",
          safe_run_id,
          "artifacts",
          binary_part(digest, 0, 2),
          digest <> ".json"
        ])

      target = safe_join!(submission_path, relative_path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- write_once(target, encoded) do
        {:ok,
         %{
           "type" => "artifact_ref",
           "version" => @version,
           "storage" => @storage,
           "kind" => kind,
           "submission_id" => submission_id,
           "run_id" => run_id,
           "path" => Path.join(["artifacts", binary_part(digest, 0, 2), digest <> ".json"]),
           "relative_path" => relative_path,
           "content_type" => "application/json",
           "size_bytes" => byte_size(encoded),
           "sha256" => digest
         }}
      end
    else
      nil -> {:error, :shared_storage_unavailable}
      "" -> {:error, :shared_storage_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp write_once(target, encoded) do
    if File.exists?(target) do
      :ok
    else
      temporary = target <> ".tmp-#{System.unique_integer([:positive])}"

      with :ok <- File.write(temporary, encoded),
           :ok <- File.rename(temporary, target) do
        :ok
      else
        {:error, :eexist} ->
          File.rm(temporary)
          :ok

        {:error, reason} ->
          File.rm(temporary)
          {:error, reason}
      end
    end
  end

  defp resolve_until!(reference, candidates, deadline) do
    case Enum.find(candidates, &File.regular?/1) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise NotReadyError,
            message:
              "artifact_not_ready: #{reference["submission_id"]}/#{reference["relative_path"]}"
        else
          Process.sleep(100)
          resolve_until!(reference, candidates, deadline)
        end

      path ->
        encoded = File.read!(path)
        verify!(reference, encoded)

        case Jason.decode(encoded) do
          {:ok, value} -> value
          {:error, _reason} -> raise IntegrityError, message: "staged artifact is not valid JSON"
        end
    end
  end

  defp resolve_pointer_until!(path, opts, deadline) do
    if File.regular?(path) do
      with {:ok, encoded} <- File.read(path),
           {:ok, %{"result_ref" => reference}} <- Jason.decode(encoded),
           true <- ref?(reference) do
        resolve!(reference, opts)
      else
        _ -> raise IntegrityError, message: "staged worker result pointer is invalid"
      end
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise NotReadyError, message: "artifact_not_ready: #{path}"
      else
        Process.sleep(100)
        resolve_pointer_until!(path, opts, deadline)
      end
    end
  end

  defp verify!(reference, encoded) do
    actual_digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)

    cond do
      byte_size(encoded) != reference["size_bytes"] ->
        raise IntegrityError, message: "staged artifact size mismatch"

      actual_digest != reference["sha256"] ->
        raise IntegrityError, message: "staged artifact checksum mismatch"

      true ->
        :ok
    end
  end

  defp candidate_paths(reference, opts) do
    relative_path = reference["relative_path"]

    direct =
      case Keyword.get(opts, :submission_path) do
        path when is_binary(path) and path != "" -> [safe_join!(path, relative_path)]
        _ -> []
      end

    shared =
      SharedStorage.root()
      |> Path.join("submissions")
      |> Path.join(safe_component(reference["submission_id"]))
      |> safe_join!(relative_path)

    Enum.uniq(direct ++ [shared])
  end

  defp submission_path(opts) do
    case Keyword.get(opts, :submission_path) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :shared_storage_unavailable}
    end
  end

  defp storage_metadata(%{metadata: metadata}), do: storage_metadata(%{"metadata" => metadata})

  defp storage_metadata(%{"metadata" => metadata}) when is_map(metadata) do
    value = map_get(metadata, "mn_storage")
    if is_map(value), do: value, else: %{}
  end

  defp storage_metadata(_manifest), do: %{}

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil

  defp safe_join!(root, relative_path) do
    expanded_root = Path.expand(root)
    target = Path.expand(relative_path, expanded_root)

    if target == expanded_root or String.starts_with?(target, expanded_root <> "/") do
      target
    else
      raise ArgumentError, "staged artifact path escapes shared storage"
    end
  end

  defp safe_component(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim(".-")
    |> nonempty("run")
  end

  defp nonempty("", fallback), do: fallback
  defp nonempty(value, _fallback), do: value

  defp inline_payload_max_bytes do
    case Integer.parse(System.get_env("MN_INLINE_PAYLOAD_MAX_BYTES", "#{@default_inline_bytes}")) do
      {value, ""} when value >= 0 -> value
      _ -> @default_inline_bytes
    end
  end

  defp resolve_timeout_ms do
    case Integer.parse(System.get_env("MN_ARTIFACT_RESOLVE_TIMEOUT_MS", "#{@default_timeout_ms}")) do
      {value, ""} when value >= 0 -> value
      _ -> @default_timeout_ms
    end
  end
end
