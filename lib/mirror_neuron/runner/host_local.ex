defmodule MirrorNeuron.Runner.HostLocal do
  alias MirrorNeuron.Message
  alias MirrorNeuron.Config

  @result_start "__MN_RESULT_START__"
  @result_end "__MN_RESULT_END__"

  def run(payload, config, opts \\ []) do
    runner_name = build_runner_name(config, opts)

    base_dir =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_host_local_#{runner_name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    message = build_message(payload, config, opts)

    try do
      with :ok <- copy_uploads(base_dir, config, opts),
           {:ok, python_env} <- ensure_python_environment(config, opts),
           :ok <- write_runtime_files(base_dir, message, opts),
           {command, env, workdir} <- build_command(config, base_dir, opts, message, python_env),
           {:ok, output, exit_code} <- run_command(command, env, workdir, config),
           {:ok, result} <- extract_result(output, exit_code, runner_name, workdir) do
        if result["exit_code"] == 0 do
          {:ok, result}
        else
          {:error, result}
        end
      end
    after
      File.rm_rf(base_dir)
    end
  end

  defp build_message(payload, config, opts) do
    case Keyword.get(opts, :message) do
      nil ->
        Message.new(
          Keyword.get(opts, :job_id),
          "runtime",
          Keyword.get(opts, :agent_id),
          Map.get(config, "output_message_type", "executor_input"),
          payload,
          content_type: Map.get(config, "content_type", "application/json"),
          content_encoding: Map.get(config, "content_encoding", "identity")
        )

      message ->
        Message.normalize!(
          message,
          job_id: Keyword.get(opts, :job_id),
          to: Keyword.get(opts, :agent_id),
          content_type: Map.get(config, "content_type", "application/json"),
          content_encoding: Map.get(config, "content_encoding", "identity")
        )
    end
  end

  defp write_runtime_files(base_dir, message, opts) do
    with :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_input.json"),
             Jason.encode!(Message.body(message), pretty: true)
           ),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_message.json"),
             Jason.encode!(message, pretty: true)
           ),
         {:ok, body_binary} <- Message.body_binary(message),
         :ok <- File.write(Path.join(base_dir, "mirror_neuron_body.bin"), body_binary),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_context.json"),
             Jason.encode!(
               %{
                 job_id: Keyword.get(opts, :job_id),
                 agent_id: Keyword.get(opts, :agent_id),
                 agent_type: Keyword.get(opts, :agent_type),
                 template_type: Keyword.get(opts, :template_type, "generic"),
                 agent_state: Keyword.get(opts, :agent_state, %{}),
                 timestamp: MirrorNeuron.Runtime.timestamp()
               },
               pretty: true
             )
           ) do
      :ok
    end
  end

  defp build_command(config, base_dir, opts, message, python_env) do
    workdir = resolve_workdir(config, base_dir)
    input_file = Path.join(base_dir, "mirror_neuron_input.json")
    context_file = Path.join(base_dir, "mirror_neuron_context.json")
    message_file = Path.join(base_dir, "mirror_neuron_message.json")
    body_file = Path.join(base_dir, "mirror_neuron_body.bin")

    substitutions = %{
      "input_file" => input_file,
      "context_file" => context_file,
      "message_file" => message_file,
      "body_file" => body_file,
      "workdir" => workdir,
      "job_id" => Keyword.get(opts, :job_id, ""),
      "agent_id" => Keyword.get(opts, :agent_id, "")
    }

    configured_command =
      case Map.get(config, "command") do
        nil ->
          "python3 - <<'PY'\nprint('No command configured for host-local worker')\nPY"

        command when is_binary(command) ->
          substitute(command, substitutions)

        command when is_list(command) ->
          command
          |> Enum.map(&substitute(to_string(&1), substitutions))
      end

    env =
      runtime_env(input_file, context_file, message_file, body_file, workdir, message, opts)
      |> Map.merge(extra_env(config))
      |> apply_python_environment_env(python_env)
      |> Enum.map(fn {key, value} -> {key, value} end)

    command_size = command_size(configured_command)

    if command_size > max_command_length() do
      {:error, "command exceeds MN_MAX_COMMAND_LENGTH"}
    else
      {normalize_command(configured_command, python_env), env, workdir}
    end
  end

  defp max_command_length do
    System.get_env("MN_MAX_COMMAND_LENGTH", "32768")
    |> String.to_integer()
  end

  defp command_size(command) when is_binary(command), do: byte_size(command)
  defp command_size(command) when is_list(command), do: command |> Enum.join("\0") |> byte_size()

  defp normalize_command(command, python_env) when is_list(command),
    do: rewrite_python_command(command, python_env)

  defp normalize_command(command, _python_env) when is_binary(command) do
    stdout_file = "mirror_neuron_stdout.txt"
    stderr_file = "mirror_neuron_stderr.txt"

    wrapper = """
    set +e
    #{command} >#{shell_escape(stdout_file)} 2>#{shell_escape(stderr_file)}
    status=$?
    MN_EXIT_CODE="$status" python3 - <<'PY'
    import json
    import os
    import pathlib

    stdout = pathlib.Path(#{shell_escape(stdout_file)}).read_text()
    stderr = pathlib.Path(#{shell_escape(stderr_file)}).read_text()
    result = {
        "exit_code": int(os.environ["MN_EXIT_CODE"]),
        "stdout": stdout,
        "stderr": stderr,
    }
    print("#{@result_start}")
    print(json.dumps(result))
    print("#{@result_end}")
    PY
    exit "$status"
    """

    ["bash", "-lc", wrapper]
  end

  defp rewrite_python_command([], _python_env), do: []
  defp rewrite_python_command(command, nil), do: command

  defp rewrite_python_command([executable | args], %{python: python}) do
    if Path.basename(executable) in ["python", "python3"] do
      [python | args]
    else
      [executable | args]
    end
  end

  defp run_command([command | args], env, workdir, config) do
    executable = System.find_executable(command) || command
    max_output_bytes = max_output_bytes(config)
    timeout_ms = timeout_ms(config)
    deadline = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:cd, String.to_charlist(workdir)},
          {:env,
           Enum.map(env, fn {key, value} ->
             {String.to_charlist(key), String.to_charlist(value)}
           end)}
        ]
      )

    collect_port_output(port, [], 0, max_output_bytes, deadline)
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{command}: #{Exception.message(error)}"}
  end

  defp collect_port_output(port, chunks, bytes, max_output_bytes, deadline) do
    timeout = receive_timeout(deadline)

    receive do
      {^port, {:data, data}} ->
        {next_chunks, next_bytes} = append_output(chunks, bytes, data, max_output_bytes)
        collect_port_output(port, next_chunks, next_bytes, max_output_bytes, deadline)

      {^port, {:exit_status, exit_code}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), exit_code}
    after
      timeout ->
        Port.close(port)

        {:error,
         %{
           "error" => "host local command timed out",
           "timeout_ms" => max(timeout || 0, 0),
           "stdout" => chunks |> Enum.reverse() |> IO.iodata_to_binary()
         }}
    end
  end

  defp append_output(chunks, bytes, data, max_output_bytes) do
    cond do
      bytes >= max_output_bytes ->
        {chunks, bytes + byte_size(data)}

      bytes + byte_size(data) <= max_output_bytes ->
        {[data | chunks], bytes + byte_size(data)}

      true ->
        remaining = max(max_output_bytes - bytes, 0)
        truncated = binary_part(data, 0, remaining) <> "\n[truncated by host local output cap]"
        {[truncated | chunks], bytes + byte_size(data)}
    end
  end

  defp receive_timeout(nil), do: :infinity

  defp receive_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp timeout_ms(config) do
    case Map.get(config, "timeout_seconds") do
      value when is_integer(value) and value > 0 -> value * 1000
      value when is_float(value) and value > 0 -> trunc(value * 1000)
      _ -> nil
    end
  end

  defp max_output_bytes(config) do
    case Map.get(config, "max_output_bytes") do
      value when is_integer(value) and value > 0 -> value
      _ -> System.get_env("MN_MAX_ARTIFACT_BYTES", "1048576") |> String.to_integer()
    end
  end

  defp extract_result(output, runner_exit_code, runner_name, workdir) do
    pattern = ~r/#{@result_start}\s*(\{.*?\})\s*#{@result_end}/s

    case Regex.run(pattern, output, capture: :all_but_first) do
      [json_blob] ->
        with {:ok, parsed} <- Jason.decode(json_blob) do
          logs =
            output
            |> String.replace(pattern, "")
            |> String.trim()

          {:ok,
           sanitize_result(%{
             "sandbox_name" => runner_name,
             "remote_dir" => workdir,
             "exit_code" => parsed["exit_code"],
             "runner_exit_code" => runner_exit_code,
             "stdout" => parsed["stdout"],
             "stderr" => parsed["stderr"],
             "logs" => logs,
             "raw_output" => output,
             "runner" => "host_local",
             "node_name" => to_string(Node.self())
           })}
        else
          {:error, error} -> {:error, Exception.message(error)}
        end

      _ ->
        {:ok,
         sanitize_result(%{
           "sandbox_name" => runner_name,
           "remote_dir" => workdir,
           "exit_code" => runner_exit_code,
           "runner_exit_code" => runner_exit_code,
           "stdout" => String.trim(output),
           "stderr" => "",
           "logs" => String.trim(output),
           "raw_output" => output,
           "runner" => "host_local",
           "node_name" => to_string(Node.self())
         })}
    end
  end

  defp sanitize_result(result) do
    Enum.into(result, %{}, fn
      {key, value} when is_binary(value) ->
        {key, value |> redact_secrets() |> truncate_artifact()}

      entry ->
        entry
    end)
  end

  defp redact_secrets(text) do
    System.get_env()
    |> Enum.filter(fn {key, value} ->
      value != "" and String.match?(key, ~r/(TOKEN|SECRET|KEY|COOKIE|PASSWORD)/i)
    end)
    |> Enum.reduce(text, fn {_key, value}, acc -> String.replace(acc, value, "[REDACTED]") end)
  end

  defp truncate_artifact(text) do
    max_bytes =
      System.get_env("MN_MAX_ARTIFACT_BYTES", "1048576")
      |> String.to_integer()

    if byte_size(text) > max_bytes do
      binary_part(text, 0, max_bytes) <> "\n[truncated by MN_MAX_ARTIFACT_BYTES]"
    else
      text
    end
  end

  defp copy_uploads(base_dir, config, opts) do
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
        copy_upload_entry(source, target, coordinator_node)
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_upload_entry(source, target, coordinator_node) do
    is_local = coordinator_node == Node.self()

    cond do
      is_local and File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))

        case File.cp_r(source, target) do
          {:ok, _files} -> {:cont, :ok}
          {:error, reason, _file} -> {:halt, {:error, inspect(reason)}}
        end

      is_local and File.exists?(source) ->
        File.mkdir_p!(Path.dirname(target))

        case File.cp(source, target) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, inspect(reason)}}
        end

      not is_local ->
        copy_remote_upload(source, target, coordinator_node)

      true ->
        {:halt, {:error, "upload source does not exist locally: #{source}"}}
    end
  end

  defp copy_remote_upload(source, target, coordinator_node) do
    is_dir = :rpc.call(coordinator_node, File, :dir?, [source], 30_000)

    if is_dir == true do
      files = :rpc.call(coordinator_node, __MODULE__, :list_all_files, [source], 30_000)

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
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
    else
      []
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
      {:error, "upload target must stay inside sandbox workspace: #{target}"}
    end
  end

  defp inside_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp ensure_python_environment(config, opts) do
    with {:ok, spec} <- python_environment_spec(config, opts) do
      case spec do
        nil -> {:ok, nil}
        spec -> ensure_cached_python_environment(spec)
      end
    end
  end

  defp python_environment_spec(config, opts) do
    case get_config(config, "python_environment") do
      nil ->
        {:ok, nil}

      raw when is_map(raw) ->
        normalize_python_environment(raw, config, opts)

      _ ->
        {:error, "python_environment must be an object"}
    end
  end

  defp normalize_python_environment(raw, config, opts) do
    with {:ok, requirements_path} <- normalize_requirements_path(get_config(raw, "requirements")),
         {:ok, packages} <- normalize_python_packages(get_config(raw, "packages")),
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
    if safe_relative_path?(path) do
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

    if inside_path?(resolved, payloads_root) do
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

  defp ensure_cached_python_environment(%{python: python} = spec) do
    with {:ok, python_version} <- python_version(python) do
      fingerprint = python_environment_fingerprint(spec, python_version)
      root = python_environment_cache_root()
      env_dir = Path.join(root, fingerprint)
      ready_file = Path.join(env_dir, ".ready")

      if python_environment_ready?(env_dir, ready_file) do
        _ = write_python_environment_metadata(env_dir, spec, python_version, fingerprint)
        {:ok, python_environment(env_dir)}
      else
        build_with_python_environment_lock(env_dir, ready_file, spec, python_version, fingerprint)
      end
    end
  end

  defp build_with_python_environment_lock(env_dir, ready_file, spec, python_version, fingerprint) do
    lock_dir = env_dir <> ".lock"
    File.mkdir_p!(Path.dirname(lock_dir))

    with :ok <- acquire_python_environment_lock(lock_dir) do
      try do
        if python_environment_ready?(env_dir, ready_file) do
          _ = write_python_environment_metadata(env_dir, spec, python_version, fingerprint)
          {:ok, python_environment(env_dir)}
        else
          build_python_environment(env_dir, ready_file, spec, python_version, fingerprint)
        end
      after
        File.rm_rf(lock_dir)
      end
    end
  end

  defp acquire_python_environment_lock(lock_dir) do
    deadline =
      System.monotonic_time(:millisecond) +
        python_environment_setup_timeout_ms()

    acquire_python_environment_lock(lock_dir, deadline)
  end

  defp acquire_python_environment_lock(lock_dir, deadline) do
    case File.mkdir(lock_dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, "timed out waiting for python_environment setup lock: #{lock_dir}"}
        else
          Process.sleep(200)
          acquire_python_environment_lock(lock_dir, deadline)
        end

      {:error, reason} ->
        {:error, "failed to create python_environment setup lock #{lock_dir}: #{reason}"}
    end
  end

  defp build_python_environment(env_dir, ready_file, spec, python_version, fingerprint) do
    File.rm_rf(env_dir)
    File.mkdir_p!(Path.dirname(env_dir))

    with {:ok, _output} <-
           run_python_setup_command(
             spec.python,
             ["-m", "venv", env_dir],
             "create python_environment virtualenv"
           ),
         :ok <- write_requirements_snapshot(env_dir, spec),
         {:ok, _output} <- install_python_environment_dependencies(env_dir, spec),
         :ok <- write_python_environment_metadata(env_dir, spec, python_version, fingerprint),
         :ok <- File.write(ready_file, MirrorNeuron.Runtime.timestamp() <> "\n") do
      {:ok, python_environment(env_dir)}
    else
      {:error, reason} ->
        File.rm_rf(env_dir)
        {:error, reason}
    end
  end

  defp write_requirements_snapshot(_env_dir, %{requirements: nil}), do: :ok

  defp write_requirements_snapshot(env_dir, %{requirements: requirements}) do
    File.mkdir_p!(env_dir)
    File.write(Path.join(env_dir, "requirements.txt"), requirements.content)
  end

  defp install_python_environment_dependencies(env_dir, spec) do
    python = Path.join([env_dir, "bin", "python"])

    requirement_args =
      case spec.requirements do
        nil ->
          []

        %{install_path: install_path} when is_binary(install_path) ->
          ["-r", install_path]

        _ ->
          ["-r", Path.join(env_dir, "requirements.txt")]
      end

    args = ["-m", "pip", "install"] ++ requirement_args ++ spec.packages
    run_python_setup_command(python, args, "install python_environment dependencies")
  end

  defp run_python_setup_command(executable, args, action) do
    case System.cmd(executable, args,
           stderr_to_stdout: true,
           env: [
             {"PIP_DISABLE_PIP_VERSION_CHECK", "1"},
             {"PIP_NO_INPUT", "1"}
           ]
         ) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error,
         "#{action} failed with exit code #{status}: #{truncate_setup_output(String.trim(output))}"}
    end
  rescue
    error in ErlangError ->
      {:error, "#{action} failed: #{Exception.message(error)}"}
  end

  defp python_environment(env_dir) do
    %{
      dir: env_dir,
      bin: Path.join(env_dir, "bin"),
      python: Path.join([env_dir, "bin", "python"])
    }
  end

  defp python_environment_ready?(env_dir, ready_file) do
    File.exists?(ready_file) and File.exists?(Path.join([env_dir, "bin", "python"]))
  end

  defp python_environment_fingerprint(spec, python_version) do
    requirements_content =
      case spec.requirements do
        nil -> ""
        requirements -> requirements.content
      end

    :crypto.hash(:sha256, [
      "mirror-neuron-python-env-v2",
      "\0",
      spec.blueprint_id || "",
      "\0",
      python_version,
      "\0",
      requirements_content,
      "\0",
      Jason.encode!(spec.packages)
    ])
    |> Base.encode16(case: :lower)
  end

  defp write_python_environment_metadata(env_dir, spec, python_version, fingerprint) do
    metadata = %{
      "schema_version" => 1,
      "resource_type" => "python_venv",
      "blueprint_id" => spec.blueprint_id,
      "fingerprint" => fingerprint,
      "python_version" => python_version,
      "requirements" => requirements_metadata(spec.requirements),
      "packages" => spec.packages,
      "last_used_at" => MirrorNeuron.Runtime.timestamp()
    }

    File.write(
      Path.join(env_dir, ".mn-blueprint-resource.json"),
      Jason.encode!(metadata, pretty: true)
    )
  end

  defp requirements_metadata(nil), do: nil

  defp requirements_metadata(requirements) do
    %{
      "path" => requirements.path,
      "sha256" => :crypto.hash(:sha256, requirements.content) |> Base.encode16(case: :lower)
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
    System.find_executable("python3") || System.find_executable("python") || "python3"
  end

  defp python_environment_cache_root do
    System.get_env("MN_BLUEPRINT_PYTHON_ENVS_DIR") ||
      Path.join(Config.string("MN_TEMP_DIR", :temp_dir), "blueprint_python_envs")
  end

  defp python_environment_setup_timeout_ms do
    case Integer.parse(System.get_env("MN_BLUEPRINT_PYTHON_ENV_SETUP_TIMEOUT_MS", "600000")) do
      {timeout, ""} when timeout > 0 -> timeout
      _ -> 600_000
    end
  end

  defp apply_python_environment_env(env, nil), do: env

  defp apply_python_environment_env(env, python_env) do
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

  defp safe_relative_path?(path) when is_binary(path) do
    Path.type(path) == :relative and
      ".." not in Path.split(path) and
      not String.starts_with?(path, "..") and
      not String.contains?(path, "/../") and
      path not in ["", "."]
  end

  defp safe_relative_path?(_path), do: false

  defp truncate_setup_output(output) do
    max_bytes = 4_000

    if byte_size(output) > max_bytes do
      binary_part(output, 0, max_bytes) <> "\n[truncated]"
    else
      output
    end
  end

  defp get_config(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, String.to_atom(key))
  end

  defp blueprint_id_from_config(config) do
    environment =
      case get_config(config, "environment") do
        env when is_map(env) -> env
        _ -> %{}
      end

    direct = get_config(environment, "MN_BLUEPRINT_ID")

    cond do
      is_binary(direct) and String.trim(direct) != "" ->
        String.trim(direct)

      true ->
        blueprint_id_from_config_json(get_config(environment, "MN_BLUEPRINT_CONFIG_JSON"))
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

  defp resolve_workdir(config, base_dir) do
    default_root = Map.get(config, "sandbox_upload_path", "/sandbox/job")
    configured = Map.get(config, "workdir", base_dir)

    cond do
      configured == default_root ->
        base_dir

      String.starts_with?(configured, default_root <> "/") ->
        suffix = String.replace_prefix(configured, default_root, "")
        base_dir <> suffix

      true ->
        configured
    end
  end

  defp runtime_env(input_file, context_file, message_file, body_file, workdir, message, opts) do
    %{
      "MN_INPUT_FILE" => input_file,
      "MN_CONTEXT_FILE" => context_file,
      "MN_MESSAGE_FILE" => message_file,
      "MN_BODY_FILE" => body_file,
      "MN_BODY_CONTENT_TYPE" => Message.content_type(message),
      "MN_BODY_CONTENT_ENCODING" => Message.content_encoding(message),
      "MN_AGENT_TYPE" => to_string(Keyword.get(opts, :agent_type, "")),
      "MN_AGENT_TEMPLATE" => Keyword.get(opts, :template_type, "generic"),
      "MN_JOB_ID" => to_string(Keyword.get(opts, :job_id, "")),
      "MN_AGENT_ID" => to_string(Keyword.get(opts, :agent_id, "")),
      "MN_WORKDIR" => workdir
    }
  end

  defp extra_env(config) do
    explicit =
      config
      |> Map.get("environment", %{})
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)

    passthrough =
      config
      |> Map.get("pass_env", [])
      |> Enum.reduce(%{}, fn key, acc ->
        env_key = to_string(key)

        case System.get_env(env_key) do
          nil -> acc
          value -> Map.put(acc, env_key, value)
        end
      end)

    Map.merge(explicit, passthrough)
  end

  defp build_runner_name(config, opts) do
    prefix = Map.get(config, "name_prefix", "host-local")
    job_id = Keyword.get(opts, :job_id, "job")
    agent_id = Keyword.get(opts, :agent_id, "agent")

    [prefix, job_id, agent_id]
    |> Enum.join("-")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.trim("-")
  end

  defp substitute(template, substitutions) do
    Enum.reduce(substitutions, template, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", value)
    end)
  end

  defp shell_escape(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end
end
