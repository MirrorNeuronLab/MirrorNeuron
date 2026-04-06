defmodule MirrorNeuron.Sandbox.OpenShell do
  alias MirrorNeuron.Message
  alias MirrorNeuron.Sandbox.JobSandbox

  @result_start "__MIRROR_NEURON_RESULT_START__"
  @result_end "__MIRROR_NEURON_RESULT_END__"

  def run(payload, config, opts \\ []) do
    config = resolve_local_cli_paths(config, opts)

    if reuse_shared_sandbox?(config) do
      run_in_shared_sandbox(payload, config, opts)
    else
      run_one_shot(payload, config, opts)
    end
  end

  defp run_one_shot(payload, config, opts) do
    sandbox_name = build_sandbox_name(config, opts)
    executable = sandbox_cli(config)
    remote_dir = Map.get(config, "sandbox_upload_path", "/sandbox/job")

    with {:ok, staged_dir} <- stage_workspace(payload, config, opts) do
      try do
        with {:ok, args} <- build_args(sandbox_name, staged_dir, remote_dir, config, opts),
             {:ok, output, openshell_exit_code} <- run_command(executable, args),
             {:ok, result} <-
               extract_result(output, sandbox_name, remote_dir, openshell_exit_code) do
          if result["exit_code"] == 0 do
            {:ok, result}
          else
            {:error, result}
          end
        end
      after
        File.rm_rf(staged_dir)
      end
    end
  end

  defp run_in_shared_sandbox(payload, config, opts) do
    executable = sandbox_cli(config)

    with {:ok, sandbox} <- JobSandbox.ensure(Keyword.fetch!(opts, :job_id), config),
         {:ok, staged_dir} <- stage_workspace(payload, config, opts) do
      remote_dir = build_shared_remote_dir(config, opts)

      try do
        with {:ok, :uploaded} <-
               upload_workspace(
                 executable,
                 sandbox["sandbox_name"],
                 staged_dir,
                 remote_dir
               ),
             command <- build_command(config, remote_dir, opts),
             {:ok, output, ssh_exit_code} <-
               run_ssh_command(config, sandbox["sandbox_name"], sandbox["ssh_host"], command),
             {:ok, result} <-
               extract_result(output, sandbox["sandbox_name"], remote_dir, ssh_exit_code) do
          if result["exit_code"] == 0 do
            {:ok, result}
          else
            {:error, result}
          end
        end
      after
        File.rm_rf(staged_dir)
      end
    end
  end

  defp build_args(sandbox_name, staged_dir, remote_dir, config, opts) do
    command =
      config
      |> build_command(remote_dir, opts)
      |> List.wrap()

    args =
      [
        "sandbox",
        "create",
        "--name",
        sandbox_name,
        "--upload",
        "#{staged_dir}:#{remote_dir}",
        "--no-git-ignore"
      ]
      |> maybe_put_flag("--no-keep", Map.get(config, "no_keep", true))
      |> maybe_put_flag("--no-auto-providers", Map.get(config, "no_auto_providers", true))
      |> maybe_put_flag("--gpu", Map.get(config, "gpu", false))
      |> maybe_put_value("--from", Map.get(config, "from"))
      |> maybe_put_value("--remote", Map.get(config, "remote"))
      |> maybe_put_value("--ssh-key", Map.get(config, "ssh_key"))
      |> maybe_put_value("--policy", Map.get(config, "policy"))
      |> maybe_put_many("--provider", Map.get(config, "providers", []))
      |> maybe_put_tty(Map.get(config, "tty"))
      |> Kernel.++(["--"])
      |> Kernel.++(command)

    {:ok, args}
  end

  defp build_command(config, remote_dir, opts) do
    workdir = resolve_workdir(config, remote_dir)
    input_file = Path.join(remote_dir, "mirror_neuron_input.json")
    context_file = Path.join(remote_dir, "mirror_neuron_context.json")
    message_file = Path.join(remote_dir, "mirror_neuron_message.json")
    body_file = Path.join(remote_dir, "mirror_neuron_body.bin")
    stdout_file = Path.join(remote_dir, "mirror_neuron_stdout.txt")
    stderr_file = Path.join(remote_dir, "mirror_neuron_stderr.txt")
    message = build_message(%{}, config, opts)

    substitutions = %{
      "input_file" => input_file,
      "context_file" => context_file,
      "message_file" => message_file,
      "body_file" => body_file,
      "workdir" => workdir,
      "job_id" => Keyword.get(opts, :job_id, ""),
      "agent_id" => Keyword.get(opts, :agent_id, "")
    }

    actual_command =
      case Map.get(config, "command") do
        nil ->
          "python3 - <<'PY'\nprint('No command configured for sandbox worker')\nPY"

        command when is_binary(command) ->
          substitute(command, substitutions)

        command when is_list(command) ->
          command
          |> Enum.map(&substitute(to_string(&1), substitutions))
          |> Enum.map(&shell_escape/1)
          |> Enum.join(" ")
      end

    extra_env_exports = build_extra_env_exports(config)

    cleanup_remote_dir = cleanup_remote_dir?(config)

    cleanup_step =
      if cleanup_remote_dir do
        "rm -rf #{shell_escape(remote_dir)} >/dev/null 2>&1 || true"
      else
        ":"
      end

    wrapper = """
    set +e
    export MIRROR_NEURON_INPUT_FILE=#{shell_escape(input_file)}
    export MIRROR_NEURON_CONTEXT_FILE=#{shell_escape(context_file)}
    export MIRROR_NEURON_MESSAGE_FILE=#{shell_escape(message_file)}
    export MIRROR_NEURON_BODY_FILE=#{shell_escape(body_file)}
    export MIRROR_NEURON_BODY_CONTENT_TYPE=#{shell_escape(Message.content_type(message))}
    export MIRROR_NEURON_BODY_CONTENT_ENCODING=#{shell_escape(Message.content_encoding(message))}
    export MIRROR_NEURON_AGENT_TYPE=#{shell_escape(to_string(Keyword.get(opts, :agent_type, "")))}
    export MIRROR_NEURON_AGENT_TEMPLATE=#{shell_escape(Keyword.get(opts, :template_type, "generic"))}
    export MIRROR_NEURON_JOB_ID=#{shell_escape(Keyword.get(opts, :job_id, ""))}
    export MIRROR_NEURON_AGENT_ID=#{shell_escape(Keyword.get(opts, :agent_id, ""))}
    export MIRROR_NEURON_WORKDIR=#{shell_escape(workdir)}
    #{extra_env_exports}
    mkdir -p #{shell_escape(remote_dir)}
    cd #{shell_escape(workdir)}
    #{actual_command} >#{shell_escape(stdout_file)} 2>#{shell_escape(stderr_file)}
    status=$?
    MIRROR_NEURON_EXIT_CODE="$status" python3 - <<'PY'
    import json
    import os
    import pathlib

    stdout = pathlib.Path(#{shell_escape(stdout_file)}).read_text()
    stderr = pathlib.Path(#{shell_escape(stderr_file)}).read_text()
    result = {
        "exit_code": int(os.environ["MIRROR_NEURON_EXIT_CODE"]),
        "stdout": stdout,
        "stderr": stderr,
    }
    print("#{@result_start}")
    print(json.dumps(result))
    print("#{@result_end}")
    PY
    #{cleanup_step}
    exit "$status"
    """

    ["bash", "-lc", wrapper]
  end

  defp run_command(executable, args) do
    {output, exit_code} =
      System.cmd(executable, args,
        stderr_to_stdout: true,
        env: [
          {"NO_COLOR", "1"}
        ]
      )

    {:ok, output, exit_code}
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  defp upload_workspace(executable, sandbox_name, staged_dir, remote_dir) do
    case System.cmd(
           executable,
           ["sandbox", "upload", sandbox_name, staged_dir, remote_dir, "--no-git-ignore"],
           stderr_to_stdout: true,
           env: [{"NO_COLOR", "1"}]
         ) do
      {_output, 0} ->
        {:ok, :uploaded}

      {output, exit_code} ->
        {:error,
         %{
           "error" => "failed to upload workspace to shared sandbox",
           "sandbox_name" => sandbox_name,
           "remote_dir" => remote_dir,
           "exit_code" => exit_code,
           "logs" => output
         }}
    end
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  defp run_ssh_command(config, sandbox_name, ssh_host, command) do
    ssh_bin = Map.get(config, "ssh_bin", "ssh")
    executable = sandbox_cli(config)

    temp_config =
      Path.join(
        System.get_env("MIRROR_NEURON_TEMP_DIR") || "/temp/mirror_neuron",
        "mirror_neuron_ssh_#{System.unique_integer([:positive])}"
      )

    try do
      case System.cmd(executable, ["sandbox", "ssh-config", sandbox_name],
             stderr_to_stdout: true,
             env: [{"NO_COLOR", "1"}]
           ) do
        {ssh_config, 0} ->
          File.write!(temp_config, ssh_config)
          run_command(ssh_bin, ["-F", temp_config, ssh_host | command])

        {output, exit_code} ->
          {:error,
           %{
             "error" => "failed to resolve shared sandbox ssh config",
             "sandbox_name" => sandbox_name,
             "exit_code" => exit_code,
             "logs" => output
           }}
      end
    after
      File.rm_rf(temp_config)
    end
  rescue
    error in ErlangError ->
      {:error, "failed to invoke ssh for #{sandbox_name}: #{Exception.message(error)}"}
  end

  defp extract_result(output, sandbox_name, remote_dir, openshell_exit_code) do
    pattern = ~r/#{@result_start}\s*(\{.*?\})\s*#{@result_end}/s

    case Regex.run(pattern, output, capture: :all_but_first) do
      [json_blob] ->
        with {:ok, parsed} <- Jason.decode(json_blob) do
          logs =
            output
            |> String.replace(pattern, "")
            |> String.trim()

          {:ok,
           maybe_put_cleanup_warning(
             %{
               "sandbox_name" => sandbox_name,
               "remote_dir" => remote_dir,
               "exit_code" => parsed["exit_code"],
               "openshell_exit_code" => openshell_exit_code,
               "stdout" => parsed["stdout"],
               "stderr" => parsed["stderr"],
               "logs" => logs,
               "raw_output" => output
             },
             parsed["exit_code"],
             openshell_exit_code,
             logs
           )}
        else
          {:error, error} -> {:error, Exception.message(error)}
        end

      _ ->
        {:ok,
         maybe_put_cleanup_warning(
           %{
             "sandbox_name" => sandbox_name,
             "remote_dir" => remote_dir,
             "exit_code" => openshell_exit_code,
             "openshell_exit_code" => openshell_exit_code,
             "stdout" => "",
             "stderr" => "",
             "logs" => String.trim(output),
             "raw_output" => output
           },
           openshell_exit_code,
           openshell_exit_code,
           String.trim(output)
         )}
    end
  end

  defp stage_workspace(payload, config, opts) do
    sandbox_name =
      if reuse_shared_sandbox?(config) do
        "shared-#{Keyword.get(opts, :job_id, "job")}"
      else
        build_sandbox_name(config, opts)
      end

    base_dir =
      Path.join(
        System.get_env("MIRROR_NEURON_TEMP_DIR") || "/temp/mirror_neuron",
        "mirror_neuron_#{sandbox_name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    message = build_message(payload, config, opts)

    with :ok <- copy_uploads(base_dir, config, opts),
         :ok <-
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
             Path.join(base_dir, "mirror_neuron_body_meta.json"),
             Jason.encode!(
               %{
                 content_type: Message.content_type(message),
                 content_encoding: Message.content_encoding(message)
               },
               pretty: true
             )
           ),
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
      {:ok, base_dir}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
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

  defp copy_uploads(base_dir, config, opts) do
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
      source = resolve_upload_source(entry["source"], payloads_path)
      target = Path.join(base_dir, entry["target"])

      cond do
        File.dir?(source) ->
          File.mkdir_p!(Path.dirname(target))

          case File.cp_r(source, target) do
            {:ok, _files} -> {:cont, :ok}
            {:error, reason, _file} -> {:halt, {:error, inspect(reason)}}
          end

        File.exists?(source) ->
          File.mkdir_p!(Path.dirname(target))

          case File.cp(source, target) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, inspect(reason)}}
          end

        true ->
          {:halt, {:error, "upload source does not exist: #{source}"}}
      end
    end)
  end

  defp resolve_upload_source(source, nil), do: Path.expand(source)

  defp resolve_upload_source(source, payloads_path) do
    if Path.type(source) == :absolute do
      source
    else
      Path.expand(source, payloads_path)
    end
  end

  defp resolve_local_cli_paths(config, opts) do
    payloads_path =
      Keyword.get(opts, :payloads_path) ||
        Map.get(config, "__payloads_path") ||
        Map.get(config, :__payloads_path)

    config
    |> resolve_local_cli_path("policy", payloads_path)
    |> resolve_local_cli_path("ssh_key", payloads_path)
  end

  defp resolve_local_cli_path(config, _key, nil), do: config

  defp resolve_local_cli_path(config, key, payloads_path) do
    case Map.get(config, key) do
      nil ->
        config

      value when is_binary(value) ->
        resolved =
          if Path.type(value) == :absolute do
            value
          else
            Path.expand(value, payloads_path)
          end

        Map.put(config, key, resolved)

      _other ->
        config
    end
  end

  defp build_sandbox_name(config, opts) do
    prefix = Map.get(config, "name_prefix", "mirror-neuron")
    job_id = Keyword.get(opts, :job_id, "job")
    agent_id = Keyword.get(opts, :agent_id, "agent")
    attempt = Keyword.get(opts, :attempt, 1)

    sanitized_base =
      [prefix, job_id, agent_id]
      |> Enum.join("-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    digest =
      [prefix, job_id, agent_id]
      |> Enum.join("|")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 10)

    suffix = "#{digest}-a#{attempt}"
    base_limit = max(63 - String.length(suffix) - 1, 0)

    sanitized_base
    |> String.slice(0, base_limit)
    |> String.trim("-")
    |> case do
      "" -> suffix
      base -> "#{base}-#{suffix}"
    end
  end

  defp build_shared_remote_dir(config, opts) do
    root = Map.get(config, "sandbox_upload_path", "/sandbox/job")
    agent = sanitize_path_segment(Keyword.get(opts, :agent_id, "agent"))
    attempt = Keyword.get(opts, :attempt, 1)
    unique = Integer.to_string(System.unique_integer([:positive]))

    if persistent_workspace?(config) do
      Path.join([root, "agents", agent])
    else
      Path.join([root, "runs", agent, "a#{attempt}-#{unique}"])
    end
  end

  defp resolve_workdir(config, remote_dir) do
    default_root = Map.get(config, "sandbox_upload_path", "/sandbox/job")
    configured = Map.get(config, "workdir", remote_dir)

    cond do
      configured == default_root ->
        remote_dir

      String.starts_with?(configured, default_root <> "/") ->
        suffix = String.replace_prefix(configured, default_root, "")
        remote_dir <> suffix

      true ->
        configured
    end
  end

  defp reuse_shared_sandbox?(config), do: Map.get(config, "reuse_shared_sandbox", true)

  defp persistent_workspace?(config), do: Map.get(config, "persistent_workspace", false)

  defp cleanup_remote_dir?(config) do
    Map.get(config, "cleanup_remote_dir", not persistent_workspace?(config))
  end

  defp sandbox_cli(config) do
    Map.get(config, "sandbox_cli", System.get_env("MIRROR_NEURON_OPENSHELL_BIN", "openshell"))
  end

  defp sanitize_path_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
  end

  defp build_extra_env_exports(config) do
    explicit =
      config
      |> Map.get("environment", %{})
      |> Enum.map(fn {key, value} ->
        "export #{sanitize_env_key(key)}=#{shell_escape(to_string(value))}"
      end)

    passthrough =
      config
      |> Map.get("pass_env", [])
      |> Enum.flat_map(fn key ->
        env_key = sanitize_env_key(key)

        case System.get_env(env_key) do
          nil -> []
          value -> ["export #{env_key}=#{shell_escape(value)}"]
        end
      end)

    (explicit ++ passthrough)
    |> Enum.join("\n")
  end

  defp sanitize_env_key(key) do
    key
    |> to_string()
    |> String.trim()
    |> case do
      "" -> raise ArgumentError, "environment variable name cannot be empty"
      value -> value
    end
  end

  defp maybe_put_flag(args, _flag, false), do: args
  defp maybe_put_flag(args, flag, true), do: args ++ [flag]

  defp maybe_put_value(args, _flag, nil), do: args
  defp maybe_put_value(args, _flag, ""), do: args
  defp maybe_put_value(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_put_many(args, _flag, []), do: args

  defp maybe_put_many(args, flag, values) do
    args ++ Enum.flat_map(values, &[flag, to_string(&1)])
  end

  defp maybe_put_tty(args, nil), do: args ++ ["--no-tty"]
  defp maybe_put_tty(args, true), do: args ++ ["--tty"]
  defp maybe_put_tty(args, false), do: args ++ ["--no-tty"]

  defp maybe_put_cleanup_warning(result, worker_exit_code, openshell_exit_code, logs) do
    if worker_exit_code == 0 and openshell_exit_code != 0 do
      result
      |> Map.put(
        "warning",
        "worker command succeeded but OpenShell exited with #{openshell_exit_code} during sandbox cleanup"
      )
      |> Map.put("cleanup_logs", logs)
    else
      result
    end
  end

  defp substitute(command, substitutions) do
    Enum.reduce(substitutions, command, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp shell_escape(value) do
    "'#{String.replace(to_string(value), "'", "'\"'\"'")}'"
  end
end
