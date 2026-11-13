defmodule MirrorNeuron.Runner.DockerWorker.Uploads do
  @moduledoc "Stages bounded-root payloads and build-context inputs from local or remote owners."

  alias MirrorNeuron.Config

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
      with {:ok, source} <- resolve_upload_source(entry["source"], payloads_path),
           {:ok, target} <- resolve_upload_target(base_dir, entry["target"]) do
        copy_upload_entry(source, target, coordinator_node, config, opts)
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def copy_build_context_uploads(base_dir, config, opts) do
    entries =
      case Map.get(config, "build_context_upload_paths") do
        paths when is_list(paths) -> paths
        _ -> []
      end

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with {:ok, source} <- resolve_build_context_source(entry, config, opts),
           {:ok, target_name} <- resolve_build_context_target(entry),
           {:ok, target} <- resolve_upload_target(base_dir, target_name) do
        copy_upload_entry(
          source,
          target,
          Keyword.get(opts, :coordinator_node, Node.self()),
          config,
          opts
        )
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_build_context_target(%{"target" => target})
       when is_binary(target) and target != "",
       do: {:ok, target}

  defp resolve_build_context_target(_entry),
    do: {:error, "build_context_upload_paths entry requires target"}

  defp resolve_build_context_source(entry, config, opts) when is_map(entry) do
    source = Map.get(entry, "source")
    base = Map.get(entry, "base", "payloads")

    cond do
      not is_binary(source) or String.trim(source) == "" ->
        {:error, "build_context_upload_paths entry requires source"}

      base in ["skills_root", "mn_skills", "skills"] ->
        resolve_skills_root_source(source, config)

      base in ["workspace_root", "workspace", "repo_root"] ->
        resolve_workspace_root_source(source, config)

      true ->
        resolve_upload_source(source, Keyword.get(opts, :payloads_path))
    end
  end

  defp resolve_build_context_source(_entry, _config, _opts),
    do: {:error, "build_context_upload_paths entries must be objects"}

  defp resolve_skills_root_source(source, config) do
    environment = Map.get(config, "environment", %{})

    skills_root =
      Map.get(environment, "MN_SKILLS_ROOT") ||
        Map.get(environment, :MN_SKILLS_ROOT) ||
        Config.optional_string("MN_SKILLS_ROOT", :skills_root) ||
        System.get_env("MIRROR_NEURON_SKILLS_ROOT") ||
        System.get_env("OTTERDESK_MN_SKILLS_ROOT")

    if is_binary(skills_root) and String.trim(skills_root) != "" do
      root = Path.expand(skills_root)

      resolved =
        if Path.type(source) == :absolute do
          Path.expand(source)
        else
          Path.expand(source, root)
        end

      cond do
        not inside_path?(resolved, root) ->
          {:error,
           "build_context_upload_paths skills source must stay inside MN_SKILLS_ROOT: #{source}"}

        File.exists?(resolved) ->
          {:ok, resolved}

        true ->
          {:error, "build_context_upload_paths skills source does not exist: #{source}"}
      end
    else
      {:error, "build_context_upload_paths entry uses skills_root but MN_SKILLS_ROOT is not set"}
    end
  end

  defp resolve_workspace_root_source(source, config) do
    environment = Map.get(config, "environment", %{})

    workspace_root =
      Map.get(environment, "MN_WORKSPACE_ROOT") ||
        Map.get(environment, :MN_WORKSPACE_ROOT) ||
        Config.optional_string("MN_WORKSPACE_ROOT", :workspace_root)

    if is_binary(workspace_root) and String.trim(workspace_root) != "" do
      root = Path.expand(workspace_root)

      resolved =
        if Path.type(source) == :absolute do
          Path.expand(source)
        else
          Path.expand(source, root)
        end

      cond do
        not inside_path?(resolved, root) ->
          {:error,
           "build_context_upload_paths workspace source must stay inside MN_WORKSPACE_ROOT: #{source}"}

        File.exists?(resolved) ->
          {:ok, resolved}

        true ->
          {:error, "build_context_upload_paths workspace source does not exist: #{source}"}
      end
    else
      {:error,
       "build_context_upload_paths entry uses workspace_root but MN_WORKSPACE_ROOT is not set"}
    end
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

  defp resolve_upload_source(source, nil), do: {:ok, Path.expand(source)}

  defp resolve_upload_source(source, payloads_path) do
    payloads_root = Path.expand(payloads_path)

    resolved =
      if Path.type(source) == :absolute do
        Path.expand(source)
      else
        Path.expand(source, payloads_root)
      end

    if inside_path?(resolved, payloads_root) do
      {:ok, resolved}
    else
      {:error, "upload source must stay inside blueprint payloads: #{source}"}
    end
  end

  defp resolve_upload_target(base_dir, target) do
    resolved = Path.expand(target, base_dir)

    if inside_path?(resolved, Path.expand(base_dir)) do
      {:ok, resolved}
    else
      {:error, "upload target must stay inside docker worker workspace: #{target}"}
    end
  end

  defp inside_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
