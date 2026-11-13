defmodule MirrorNeuron.Runner.DockerWorker.Workspace do
  @moduledoc "Runs commands in prepared containers and manages invocation-owned workspace cleanup."

  require Logger

  alias MirrorNeuron.Runner.DockerWorker.Context
  alias MirrorNeuron.Runner.DockerCommand
  alias MirrorNeuron.Sandbox.DockerJobSandbox
  alias MirrorNeuron.Runner.DockerWorker.Execution
  alias MirrorNeuron.Runner.DockerWorker.Settings

  @default_container_workdir "/mn/job"

  def run_worker_command(image, base_dir, config, opts) do
    run_shared_docker(image, base_dir, config, opts)
  end

  defp run_shared_docker(image, base_dir, config, opts) do
    job_id = Keyword.fetch!(opts, :job_id)

    with {:ok, sandbox} <- DockerJobSandbox.ensure(job_id, image, config, opts),
         :ok <-
           DockerCommand.validate_runtime(Settings.docker_bin(config), sandbox["container_name"]) do
      container_name = sandbox["container_name"]
      remote_dir = build_shared_remote_dir(config, opts)
      opts = Keyword.put(opts, :docker_invocation_dir, remote_dir)

      try do
        with :ok <- prepare_shared_remote_dir(container_name, remote_dir, config),
             :ok <- copy_to_shared_container(container_name, base_dir, remote_dir, config),
             {:ok, docker_args} <-
               build_docker_exec_args(container_name, remote_dir, config, opts),
             {:ok, output, exit_code} <-
               Execution.run_docker(docker_args, container_name, config, opts) do
          {:ok, output, exit_code, container_name}
        end
      after
        stop_invocation(container_name, remote_dir, config)
        cleanup_shared_remote_dir(container_name, remote_dir, config)
      end
    end
  end

  defp build_docker_exec_args(container_name, remote_dir, config, opts) do
    workdir = resolve_shared_workdir(config, remote_dir)

    command =
      Map.get(config, "command")
      |> normalize_command()
      |> wrap_runtime_bootstrap_command()
      |> DockerCommand.wrap(remote_dir)

    env = Context.runtime_env(workdir, remote_dir, config, opts, remote_dir)

    args =
      ["exec", "-w", workdir]
      |> put_env_args(env)
      |> Kernel.++([container_name])
      |> Kernel.++(command)

    {:ok, args}
  end

  defp prepare_shared_remote_dir(container_name, remote_dir, config) do
    case System.cmd(
           Settings.docker_bin(config),
           ["exec", container_name, "mkdir", "-p", remote_dir],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  rescue
    error in ErlangError ->
      {:error, "failed to prepare shared DockerWorker workspace: #{Exception.message(error)}"}
  end

  defp copy_to_shared_container(container_name, base_dir, remote_dir, config) do
    source = Path.join(Path.expand(base_dir), ".")

    case System.cmd(
           Settings.docker_bin(config),
           ["cp", source, "#{container_name}:#{remote_dir}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  rescue
    error in ErlangError ->
      {:error,
       "failed to copy DockerWorker workspace into shared container: #{Exception.message(error)}"}
  end

  defp cleanup_shared_remote_dir(container_name, remote_dir, config) do
    if cleanup_remote_dir?(config) do
      _ =
        System.cmd(Settings.docker_bin(config), ["exec", container_name, "rm", "-rf", remote_dir],
          stderr_to_stdout: true
        )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp resolve_shared_workdir(config, remote_dir) do
    configured = container_workdir(config)

    cond do
      configured == @default_container_workdir ->
        remote_dir

      String.starts_with?(configured, @default_container_workdir <> "/") ->
        suffix = String.replace_prefix(configured, @default_container_workdir, "")
        remote_dir <> suffix

      true ->
        configured
    end
  end

  defp build_shared_remote_dir(_config, opts) do
    agent = Settings.safe_name(Keyword.get(opts, :agent_id, "agent"))
    attempt = Keyword.get(opts, :attempt, 1)
    invocation = Keyword.get(opts, :invocation, 1)
    unique = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    Path.join([
      @default_container_workdir,
      "runs",
      agent,
      "i#{invocation}-a#{attempt}-#{unique}"
    ])
  end

  defp container_workdir(config) do
    case Map.get(config, "workdir") || get_in(config, ["docker", "workdir"]) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_container_workdir
    end
  end

  defp normalize_command(nil), do: ["sh", "-lc", "echo 'No command configured for docker worker'"]

  defp normalize_command(command) when is_binary(command), do: ["sh", "-lc", command]

  defp normalize_command(command) when is_list(command), do: Enum.map(command, &to_string/1)

  defp normalize_command(command), do: ["sh", "-lc", to_string(command)]

  defp cleanup_remote_dir?(config) do
    Map.get(config, "cleanup_remote_dir", true) |> Settings.truthy?()
  end

  defp put_env_args(args, env) do
    env
    |> Enum.reduce(args, fn {key, value}, acc -> acc ++ ["-e", "#{key}=#{value}"] end)
  end

  defp wrap_runtime_bootstrap_command(command) do
    [
      "sh",
      "-lc",
      """
      for root in "$MN_WORKDIR/.mn-local-skills" "$MN_BUNDLE_ROOT/.mn-local-skills" "/mn/job/.mn-local-skills"; do
        if [ -d "$root" ]; then
          for src in "$root"/*/src; do
            if [ -d "$src" ]; then
              PYTHONPATH="$src${PYTHONPATH:+:$PYTHONPATH}"
            fi
          done
        fi
      done
      export PYTHONPATH
      exec "$@"
      """,
      "mn-docker-worker-runtime"
    ] ++ command
  end

  defp stop_invocation(container_name, remote_dir, config) do
    case DockerCommand.stop(Settings.docker_bin(config), container_name, remote_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("DockerWorker invocation cleanup failed; retrying: #{inspect(reason)}")
        Process.sleep(1_000)
        stop_invocation(container_name, remote_dir, config)
    end
  end
end
