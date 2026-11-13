defmodule MirrorNeuron.Runner.HostLocal.Uploads do
  @moduledoc "Stages declared local and remote payloads and artifact references."

  alias MirrorNeuron.Runner.HostLocal.Paths

  def copy_uploads(base_dir, config, opts) do
    payloads_path = Keyword.get(opts, :payloads_path)
    coordinator_node = Keyword.get(opts, :coordinator_node, Node.self())

    entries =
      case Map.get(config, "upload_paths") do
        paths when is_list(paths) and paths != [] ->
          Enum.map(paths, fn entry ->
            %{
              "source" => Map.fetch!(entry, "source"),
              "target" => Map.get(entry, "target", Path.basename(Map.fetch!(entry, "source")))
            }
          end)

        _ ->
          case Map.get(config, "upload_path") do
            nil ->
              []

            source ->
              [
                %{
                  "source" => source,
                  "target" => Map.get(config, "upload_as", Path.basename(source))
                }
              ]
          end
      end

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with {:ok, source} <- Paths.resolve_upload_source(entry["source"], payloads_path),
           {:ok, target} <- Paths.resolve_upload_target(base_dir, entry["target"]) do
        copy_upload_entry(source, target, coordinator_node, config, opts)
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_upload_entry(source, target, coordinator_node, config, opts) do
    is_local = coordinator_node == Node.self()

    artifact_result =
      MirrorNeuron.Runner.Uploads.materialize_artifacts(source, target, config, opts)

    cond do
      is_local and File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp_r(source, target)
        |> case do
          {:ok, _files} -> artifact_upload_result(artifact_result)
          {:error, reason, _file} -> {:halt, {:error, inspect(reason)}}
        end

      is_local and File.exists?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp(source, target)
        |> case do
          :ok -> artifact_upload_result(artifact_result)
          {:error, reason} -> {:halt, {:error, inspect(reason)}}
        end

      not is_local ->
        case copy_remote_upload(source, target, coordinator_node) do
          {:cont, :ok} -> artifact_upload_result(artifact_result)
          {:halt, {:error, _reason}} when artifact_result == :ok -> {:cont, :ok}
          other -> other
        end

      artifact_result == :ok ->
        {:cont, :ok}

      match?({:error, _reason}, artifact_result) ->
        {:error, reason} = artifact_result
        {:halt, {:error, reason}}

      true ->
        {:halt, {:error, "upload source does not exist locally: #{source}"}}
    end
  end

  defp artifact_upload_result(:ok), do: {:cont, :ok}

  defp artifact_upload_result(:not_found), do: {:cont, :ok}

  defp artifact_upload_result({:error, reason}), do: {:halt, {:error, reason}}

  defp copy_remote_upload(source, target, coordinator_node) do
    is_dir = :rpc.call(coordinator_node, File, :dir?, [source], 30_000)

    if is_dir == true do
      files =
        :rpc.call(
          coordinator_node,
          MirrorNeuron.Runner.HostLocal,
          :list_all_files,
          [source],
          30_000
        )

      Enum.each(files, fn rel_path ->
        content = :rpc.call(coordinator_node, File, :read!, [Path.join(source, rel_path)], 30_000)
        file_target = Path.join(target, rel_path)
        File.mkdir_p!(Path.dirname(file_target))
        File.write!(file_target, content)
      end)

      {:cont, :ok}
    else
      is_file = :rpc.call(coordinator_node, File, :exists?, [source], 30_000)

      if is_file == true do
        content = :rpc.call(coordinator_node, File, :read!, [source], 30_000)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, content)
        {:cont, :ok}
      else
        {:halt,
         {:error, "upload source does not exist remotely on #{coordinator_node}: #{source}"}}
      end
    end
  end

  @doc false
  def list_all_files(dir) do
    if File.dir?(dir) do
      do_list_all_files(dir, dir)
      |> Enum.sort()
    else
      []
    end
  end

  defp do_list_all_files(root, dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      cond do
        File.dir?(path) -> do_list_all_files(root, path)
        File.regular?(path) -> [Path.relative_to(path, root)]
        true -> []
      end
    end)
  end
end
