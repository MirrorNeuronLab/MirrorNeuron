defmodule MirrorNeuron.Runner.OpenShell.Uploads do
  @moduledoc "Resolves confined payload paths and uploads staged entries to their sandbox destinations."

  alias MirrorNeuron.Sandbox.OpenShellCLI

  @doc false
  def upload_workspace(executable, sandbox_name, staged_dir, remote_dir) do
    staged_dir
    |> staged_uploads(remote_dir)
    |> Enum.reduce_while({:ok, :uploaded}, fn {source, destination}, {:ok, :uploaded} ->
      case System.cmd(
             executable,
             ["sandbox", "upload", sandbox_name, source, destination, "--no-git-ignore"],
             stderr_to_stdout: true,
             env: OpenShellCLI.command_env()
           ) do
        {_output, 0} ->
          {:cont, {:ok, :uploaded}}

        {output, exit_code} ->
          {:halt,
           {:error,
            %{
              "error" => "failed to upload workspace to shared sandbox",
              "sandbox_name" => sandbox_name,
              "remote_dir" => remote_dir,
              "source" => source,
              "destination" => destination,
              "exit_code" => exit_code,
              "logs" => output
            }}}
      end
    end)
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  def copy_uploads(base_dir, config, opts) do
    payloads_path = Keyword.get(opts, :payloads_path)

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
        copy_upload_entry(source, target, config, opts)
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_upload_entry(source, target, config, opts) do
    artifact_result =
      MirrorNeuron.Runner.Uploads.materialize_artifacts(source, target, config, opts)

    cond do
      File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp_r(source, target)
        |> case do
          {:ok, _files} -> artifact_upload_result(artifact_result)
          {:error, reason, _file} -> {:halt, {:error, inspect(reason)}}
        end

      File.exists?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp(source, target)
        |> case do
          :ok -> artifact_upload_result(artifact_result)
          {:error, reason} -> {:halt, {:error, inspect(reason)}}
        end

      artifact_result == :ok ->
        {:cont, :ok}

      match?({:error, _reason}, artifact_result) ->
        {:error, reason} = artifact_result
        {:halt, {:error, reason}}

      true ->
        {:halt, {:error, "upload source does not exist: #{source}"}}
    end
  end

  defp artifact_upload_result(:ok), do: {:cont, :ok}

  defp artifact_upload_result(:not_found), do: {:cont, :ok}

  defp artifact_upload_result({:error, reason}), do: {:halt, {:error, reason}}

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
      {:error, "upload target must stay inside sandbox workspace: #{target}"}
    end
  end

  defp inside_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  def put_uploads(args, staged_dir, remote_dir) do
    staged_dir
    |> staged_uploads(remote_dir)
    |> Enum.reduce(args, fn {source, destination}, acc ->
      acc ++ ["--upload", "#{source}:#{destination}"]
    end)
  end

  defp staged_uploads(staged_dir, remote_dir) do
    staged_dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn entry ->
      source = Path.join(staged_dir, entry)
      destination = upload_destination(source, remote_dir)
      {source, destination}
    end)
  end

  defp upload_destination(source, remote_dir) do
    if File.dir?(source) do
      remote_dir
    else
      Path.join(remote_dir, Path.basename(source))
    end
  end
end
