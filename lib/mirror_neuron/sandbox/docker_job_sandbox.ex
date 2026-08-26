defmodule MirrorNeuron.Sandbox.DockerJobSandbox do
  @moduledoc false

  @container_root "/mn/job"

  def ensure(job_id, image, config, _opts \\ []) do
    prepared_sandbox(job_id, image, config)
  end

  def cleanup_job_local(_job_id, _config \\ %{}), do: :ok

  def reset_prepared_container(config) when is_map(config) do
    case prepared_container_name(config) do
      name when is_binary(name) and name != "" ->
        case docker_cmd(["restart", "--time", "1", name], config) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _missing ->
        :ok
    end
  end

  def reset_prepared_container(_config), do: :ok

  @doc false
  def prepared_container?(config) do
    case prepared_container_name(config) do
      name when is_binary(name) -> String.trim(name) != ""
      _ -> false
    end
  end

  defp prepared_sandbox(job_id, image, config) do
    case prepared_container_name(config) do
      name when is_binary(name) and name != "" ->
        {:ok,
         %{
           "container_name" => name,
           "image" => image,
           "workdir_root" => @container_root
         }}

      _ ->
        {:error,
         "docker_worker sandbox for job #{job_id} is not prepared; prepare DockerWorker resources with mn-python-sdk/API/CLI and provide docker_worker_container_name or MN_DOCKER_WORKER_CONTAINER_NAME"}
    end
  end

  defp prepared_container_name(config) do
    env = config_env(config)

    Map.get(config, "docker_worker_container_name") ||
      Map.get(config, "container_name") ||
      get_in(config, ["docker", "container_name"]) ||
      Map.get(env, "MN_DOCKER_WORKER_CONTAINER_NAME") ||
      System.get_env("MN_DOCKER_WORKER_CONTAINER_NAME")
  end

  defp config_env(config) do
    case Map.get(config, "environment") do
      env when is_map(env) ->
        Enum.into(env, %{}, fn {key, value} -> {to_string(key), to_string(value)} end)

      _ ->
        %{}
    end
  end

  defp docker_cmd(args, config) do
    case System.cmd(docker_bin(config), args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end

  defp docker_bin(config) do
    Map.get(config, "docker_bin") ||
      get_in(config, ["docker", "bin"]) ||
      MirrorNeuron.Config.optional_string("MN_DOCKER_BIN", :docker_bin) ||
      System.find_executable("docker") ||
      "docker"
  end
end
