defmodule MirrorNeuron.Runner.HostLocal.PythonEnvironment do
  @moduledoc "Validates declared dependencies and resolves SDK-prepared Python environments."

  alias MirrorNeuron.Runner.HostLocal.Context
  alias MirrorNeuron.Runner.HostLocal.Paths

  def ensure_python_environment(config, opts) do
    with {:ok, spec} <- python_environment_spec(config, opts) do
      case spec do
        nil -> {:ok, nil}
        _spec -> prepared_python_environment_result(config)
      end
    end
  end

  defp prepared_python_environment_result(config) do
    case prepared_python_environment(config) do
      prepared_python_env when is_map(prepared_python_env) ->
        {:ok, prepared_python_env}

      _ ->
        {:error,
         "python_environment preparation is owned by mn-python-sdk/API/CLI; prepare the environment before submission and provide python_environment.path, MN_PYTHON_ENV, or VIRTUAL_ENV"}
    end
  end

  defp prepared_python_environment(config) do
    env = Context.extra_env(config)

    dir =
      get_in(config, ["python_environment", "path"]) ||
        get_in(config, ["python_environment", "prepared_path"]) ||
        Map.get(env, "MN_PYTHON_ENV") ||
        Map.get(env, "VIRTUAL_ENV")

    if is_binary(dir) and dir != "" do
      python_environment(Path.expand(dir))
    end
  end

  defp python_environment_spec(config, opts) do
    case Context.get_config(config, "python_environment") do
      nil ->
        {:ok, nil}

      raw when is_map(raw) ->
        normalize_python_environment(raw, config, opts)

      _ ->
        {:error, "python_environment must be an object"}
    end
  end

  defp normalize_python_environment(raw, config, opts) do
    with {:ok, requirements_path} <-
           normalize_requirements_path(Context.get_config(raw, "requirements")),
         {:ok, packages} <- normalize_python_packages(Context.get_config(raw, "packages")),
         {:ok, requirements} <- read_python_requirements(requirements_path, opts) do
      if is_nil(requirements) and packages == [] do
        {:ok, nil}
      else
        {:ok,
         %{
           requirements: requirements,
           packages: packages,
           python: host_python_executable(),
           blueprint_id: blueprint_id_from_config(config)
         }}
      end
    end
  end

  defp normalize_requirements_path(nil), do: {:ok, nil}

  defp normalize_requirements_path(""), do: {:ok, nil}

  defp normalize_requirements_path(path) when is_binary(path) do
    if Paths.safe_relative_path?(path) do
      {:ok, path}
    else
      {:error,
       "python_environment requirements must be a relative path inside payloads/: #{path}"}
    end
  end

  defp normalize_requirements_path(_path),
    do: {:error, "python_environment requirements must be a string"}

  defp normalize_python_packages(nil), do: {:ok, []}

  defp normalize_python_packages(packages) when is_list(packages) do
    if Enum.all?(packages, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, packages}
    else
      {:error, "python_environment packages must be a list of non-empty strings"}
    end
  end

  defp normalize_python_packages(_packages),
    do: {:error, "python_environment packages must be a list of strings"}

  defp read_python_requirements(nil, _opts), do: {:ok, nil}

  defp read_python_requirements(path, opts) do
    payloads_path = Keyword.get(opts, :payloads_path)
    coordinator_node = Keyword.get(opts, :coordinator_node, Node.self())

    with {:ok, source} <- resolve_dependency_source(path, payloads_path),
         {:ok, content} <- read_dependency_file(source, coordinator_node) do
      install_path =
        if coordinator_node == Node.self() do
          source
        else
          nil
        end

      {:ok, %{path: path, source: source, install_path: install_path, content: content}}
    end
  end

  defp resolve_dependency_source(_path, nil),
    do: {:error, "python_environment requirements require a blueprint payloads path"}

  defp resolve_dependency_source(path, payloads_path) do
    payloads_root = Path.expand(payloads_path)
    resolved = Path.expand(path, payloads_root)

    if Paths.inside_path?(resolved, payloads_root) do
      {:ok, resolved}
    else
      {:error, "python_environment requirements must stay inside blueprint payloads: #{path}"}
    end
  end

  defp read_dependency_file(path, coordinator_node) do
    if coordinator_node == Node.self() do
      case File.read(path) do
        {:ok, content} ->
          {:ok, content}

        {:error, reason} ->
          {:error, "python_environment requirements file is not readable: #{path} (#{reason})"}
      end
    else
      read_remote_dependency_file(path, coordinator_node)
    end
  end

  defp read_remote_dependency_file(path, coordinator_node) do
    case :rpc.call(coordinator_node, File, :read, [path], 30_000) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error,
         "python_environment requirements file is not readable on #{coordinator_node}: #{path} (#{reason})"}

      {:badrpc, reason} ->
        {:error,
         "python_environment requirements file could not be read from #{coordinator_node}: #{inspect(reason)}"}

      other ->
        {:error,
         "python_environment requirements file could not be read from #{coordinator_node}: #{inspect(other)}"}
    end
  end

  defp python_environment(env_dir) do
    %{
      dir: env_dir,
      bin: Path.join(env_dir, "bin"),
      python: Path.join([env_dir, "bin", "python"])
    }
  end

  defp python_version(python) do
    case System.cmd(python, ["--version"], stderr_to_stdout: true) do
      {version, 0} ->
        {:ok, String.trim(version)}

      {output, status} ->
        {:error, "python --version failed with exit code #{status}: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError -> {:error, "failed to invoke #{python}: #{Exception.message(error)}"}
  end

  defp host_python_executable do
    ["python3.12", "python3", "python"]
    |> Enum.map(&System.find_executable/1)
    |> Enum.find(&python_3_12?/1) || "python3.12"
  end

  defp python_3_12?(nil), do: false

  defp python_3_12?(python) do
    case python_version(python) do
      {:ok, "Python 3.12" <> _} -> true
      _ -> false
    end
  end

  def apply_python_environment_env(env, nil), do: env

  def apply_python_environment_env(env, python_env) do
    path =
      [python_env.bin, Map.get(env, "PATH") || System.get_env("PATH")]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(":")

    env
    |> Map.put("VIRTUAL_ENV", python_env.dir)
    |> Map.put("MN_PYTHON_ENV", python_env.dir)
    |> Map.put("PATH", path)
  end

  defp blueprint_id_from_config(config) do
    environment =
      case Context.get_config(config, "environment") do
        env when is_map(env) -> env
        _ -> %{}
      end

    direct = Context.get_config(environment, "MN_BLUEPRINT_ID")

    cond do
      is_binary(direct) and String.trim(direct) != "" ->
        String.trim(direct)

      true ->
        blueprint_id_from_config_json(Context.get_config(environment, "MN_BLUEPRINT_CONFIG_JSON"))
    end
  end

  defp blueprint_id_from_config_json(config_json) when is_binary(config_json) do
    with {:ok, decoded} <- Jason.decode(config_json),
         %{"identity" => %{"blueprint_id" => blueprint_id}} <- decoded,
         true <- is_binary(blueprint_id) and String.trim(blueprint_id) != "" do
      String.trim(blueprint_id)
    else
      _ -> nil
    end
  end

  defp blueprint_id_from_config_json(_config_json), do: nil
end
