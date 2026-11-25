defmodule MirrorNeuron.Sandbox.WasmtimePayload do
  @moduledoc false
  alias MirrorNeuron.Runner.Uploads
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Sandbox.WitArtifacts

  def relative?(name) when is_binary(name) do
    not String.contains?(name, ["\\", ":", <<0>>]) and
      Enum.all?(String.split(name, "/"), &(&1 not in ["", ".", ".."]))
  end

  def relative?(_), do: false

  def stage_run_inputs(_name, _target, nil, _opts), do: :not_found

  def stage_run_inputs(name, target, workflow, opts) do
    owner = Keyword.get(opts, :coordinator_node, node())
    execution = Keyword.fetch!(opts, :job_id)

    case owner_call(owner, :run_input_inventory, [execution, workflow, name]) do
      {:ok, root, folders} ->
        with :ok <- File.mkdir(target) do
          Enum.reduce_while(folders, :ok, fn folder, :ok ->
            base = folder["payload_path"]
            dest = Path.join(target, Path.relative_to(base, name))

            with :ok <- File.mkdir_p(dest),
                 :ok <- copy_inventory(owner, root, base, dest, folder["files"]) do
              {:cont, :ok}
            else
              error -> {:halt, error}
            end
          end)
        end

      result ->
        result
    end
  end

  def run_input_inventory(execution, workflow, name) do
    with true <- relative?(name),
         {:ok, record} <- MirrorNeuron.inspect_job(execution),
         %{"submission_id" => submission, "run_id" => ^workflow} <-
           SharedStorage.run_data_ref(record) do
      folders = get_in(record, ["manifest", "metadata", "mn_local_inputs", "folders"]) || []

      selected =
        Enum.filter(folders, fn f ->
          base = f["payload_path"]
          relative?(base) and (base == name or String.starts_with?(base, name <> "/"))
        end)

      if selected == [],
        do: :not_found,
        else:
          with(
            {:ok, root} <-
              WitArtifacts.directory(
                SharedStorage.root(),
                ["submissions", submission, "inputs"],
                false
              ),
            do: {:ok, root, selected}
          )
    else
      nil -> :not_found
      false -> {:error, :invalid_input_path}
      _ -> {:error, :run_scope_unavailable}
    end
  end

  defp copy_inventory(owner, root, base, dest, rows) when is_list(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      name = row["relative_path"]

      with true <- relative?(name),
           {:file, bytes} <- read(owner, root, Path.join(base, name)),
           true <-
             byte_size(bytes) == row["size_bytes"] and WitArtifacts.digest(bytes) == row["sha256"],
           path = Path.join(dest, name),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, bytes, [:exclusive]) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :staged_input_integrity_error}}
      end
    end)
  end

  defp copy_inventory(_, _, _, _, _), do: {:error, :invalid_input_inventory}

  defp owner_call(owner, f, args) when owner == node(), do: apply(__MODULE__, f, args)
  defp owner_call(owner, f, args), do: :rpc.call(owner, __MODULE__, f, args, 30_000)

  def stage(name, target, config, opts) do
    root = Keyword.get(opts, :payloads_path)
    node = Keyword.get(opts, :coordinator_node, Node.self())

    if is_binary(root) and relative?(name) do
      # Blob materialization may hard-link the content store. Copy into the
      # writable preopen so a guest can never modify a stored blob.
      staging = target <> ".materialized"

      try do
        case Uploads.materialize_artifacts(Path.join(root, name), staging, config, opts) do
          :ok ->
            case File.cp_r(staging, target) do
              {:ok, _} -> :ok
              {:error, reason, _} -> {:error, reason}
            end

          :not_found ->
            copy(node, root, name, target)

          other ->
            other
        end
      after
        File.rm_rf(staging)
      end
    else
      {:error, "Wasmtime requires a contained bundle payload path"}
    end
  end

  defp copy(node, root, name, target) do
    case read(node, root, name) do
      {:file, bytes} ->
        File.write(target, bytes, [:exclusive])

      {:directory, entries} ->
        with :ok <- File.mkdir(target) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case copy(node, root, Path.join(name, entry), Path.join(target, entry)) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end

      {:error, _} = error ->
        error

      other ->
        {:error, {:wasmtime_payload, other}}
    end
  end

  defp read(node, root, name) when node == node(), do: read_entry(root, name)
  defp read(node, root, name), do: :rpc.call(node, __MODULE__, :read_entry, [root, name], 30_000)

  # Check ancestors on the owning node, before copying anything into the guest.
  def read_entry(root, name) do
    with true <- relative?(name),
         {:ok, path} <- descend(root, String.split(name, "/")),
         {:ok, stat} <- File.lstat(path) do
      case stat.type do
        :directory -> with {:ok, names} <- File.ls(path), do: {:directory, names}
        :regular -> with {:ok, bytes} <- File.read(path), do: {:file, bytes}
        _ -> {:error, "Wasmtime payloads must be ordinary files or directories"}
      end
    else
      false -> {:error, "invalid Wasmtime payload path"}
      error -> error
    end
  end

  defp descend(path, []), do: {:ok, path}

  defp descend(path, [part | rest]) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> descend(Path.join(path, part), rest)
      {:error, :enoent} = missing -> missing
      _ -> {:error, "invalid Wasmtime payload directory"}
    end
  end
end
