defmodule MirrorNeuron.Runner.OpenShell do
  require Logger

  alias MirrorNeuron.Config
  alias MirrorNeuron.Message
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Runner.OpenShellSharedStorage
  alias MirrorNeuron.Sandbox.OpenShellCLI
  alias MirrorNeuron.Sandbox.OpenShellJobSandbox

  @result_start "__MN_RESULT_START__"
  @result_end "__MN_RESULT_END__"

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

    with {:ok, staged_dir} <- stage_workspace(payload, config, opts),
         {:ok, resource_id} <- register_one_shot_sandbox(sandbox_name, opts) do
      try do
        with {:ok, args} <- build_args(sandbox_name, staged_dir, remote_dir, config, opts),
             {:ok, output, openshell_exit_code} <- run_command(executable, args),
             :ok <-
               release_one_shot_sandbox(
                 resource_id,
                 Map.get(config, "no_keep", true),
                 openshell_exit_code
               ),
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

  defp register_one_shot_sandbox(sandbox_name, opts) do
    attrs = %{
      "operation" => "register",
      "resource_kind" => "openshell",
      "scope" => "attempt",
      "external_id" => sandbox_name,
      "job_id" => to_string(Keyword.get(opts, :job_id) || ""),
      "run_id" => to_string(Keyword.get(opts, :run_id) || ""),
      "owner_node" => to_string(Node.self()),
      "state" => "committed"
    }

    case ModelServices.native_resource_command(attrs) do
      {:ok, %{"resource_id" => resource_id}} when is_binary(resource_id) ->
        {:ok, resource_id}

      {:ok, _result} ->
        {:error, "native SDK did not return an OpenShell resource lease"}

      {:error, reason} ->
        {:error, "failed to register OpenShell sandbox ownership: #{reason}"}
    end
  end

  defp release_one_shot_sandbox(resource_id, true, 0) do
    case ModelServices.native_resource_command(%{
           "operation" => "release",
           "resource_ids" => [resource_id]
         }) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "OpenShell sandbox completed but its native resource lease could not be released: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp release_one_shot_sandbox(_resource_id, _no_keep, _openshell_exit_code), do: :ok

  defp run_in_shared_sandbox(payload, config, opts) do
    executable = sandbox_cli(config)

    with {:ok, sandbox} <- OpenShellJobSandbox.ensure(Keyword.fetch!(opts, :job_id), config) do
      remote_dir = build_shared_remote_dir(config, opts)

      prepared_config = Map.put(config, "sandbox_name", sandbox["sandbox_name"])

      with {:ok, shared_storage} <-
             OpenShellSharedStorage.plan(payload, prepared_config, remote_dir, opts),
           {:ok, staged_dir} <-
             stage_workspace(
               shared_storage.payload,
               shared_storage.config,
               shared_storage.opts
             ) do
        try do
          with {:ok, :uploaded} <-
                 upload_workspace(
                   executable,
                   sandbox["sandbox_name"],
                   staged_dir,
                   remote_dir
                 ),
               :ok <- OpenShellSharedStorage.upload(shared_storage, executable),
               {:ok, command} <-
                 build_command(shared_storage.config, remote_dir, shared_storage.opts),
               {:ok, output, ssh_exit_code} <-
                 run_ssh_command(
                   shared_storage.config,
                   sandbox["sandbox_name"],
                   sandbox["ssh_host"],
                   command
                 ) do
            with :ok <- OpenShellSharedStorage.download(shared_storage, executable),
                 :ok <-
                   cleanup_shared_storage(
                     shared_storage,
                     shared_storage.config,
                     sandbox
                   ),
                 {:ok, result} <-
                   extract_result(
                     output,
                     sandbox["sandbox_name"],
                     remote_dir,
                     ssh_exit_code
                   ) do
              if result["exit_code"] == 0 do
                {:ok, result}
              else
                {:error, result}
              end
            end
          end
        after
          File.rm_rf(staged_dir)
        end
      end
    end
  end

  defp cleanup_shared_storage(
         %OpenShellSharedStorage{enabled: false},
         _config,
         _sandbox
       ),
       do: :ok

  defp cleanup_shared_storage(
         %OpenShellSharedStorage{remote_root: remote_root},
         config,
         sandbox
       ) do
    command = ["rm -rf -- #{shell_escape(remote_root)}"]

    case run_ssh_command(
           config,
           sandbox["sandbox_name"],
           sandbox["ssh_host"],
           command
         ) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, exit_code} ->
        {:error,
         %{
           "error" => "failed to clean OpenShell shared-storage mirror",
           "remote_root" => remote_root,
           "exit_code" => exit_code,
           "logs" => output
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp build_args(sandbox_name, staged_dir, remote_dir, config, opts) do
    with {:ok, command} <- build_command(config, remote_dir, opts) do
      args =
        [
          "sandbox",
          "create",
          "--name",
          sandbox_name,
          "--no-git-ignore"
        ]
        |> put_uploads(staged_dir, remote_dir)
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
          "/usr/bin/python3 - <<'PY'\nprint('No command configured for sandbox worker')\nPY"

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
        "rm -rf #{shell_escape(remote_dir)} || true"
      else
        ":"
      end

    wrapper = """
    set +e
    export MN_INPUT_FILE=#{shell_escape(input_file)}
    export MN_CONTEXT_FILE=#{shell_escape(context_file)}
    export MN_MESSAGE_FILE=#{shell_escape(message_file)}
    export MN_BODY_FILE=#{shell_escape(body_file)}
    export MN_BODY_CONTENT_TYPE=#{shell_escape(Message.content_type(message))}
    export MN_BODY_CONTENT_ENCODING=#{shell_escape(Message.content_encoding(message))}
    export MN_AGENT_TYPE=#{shell_escape(to_string(Keyword.get(opts, :agent_type, "")))}
    export MN_AGENT_TEMPLATE=#{shell_escape(Keyword.get(opts, :template_type, "generic"))}
    export MN_JOB_ID=#{shell_escape(Keyword.get(opts, :job_id, ""))}
    export MN_AGENT_ID=#{shell_escape(Keyword.get(opts, :agent_id, ""))}
    export MN_WORKDIR=#{shell_escape(workdir)}
    #{extra_env_exports}
    mkdir -p #{shell_escape(remote_dir)}
    cd #{shell_escape(workdir)}
    (
    #{actual_command}
    ) >#{shell_escape(stdout_file)} 2>#{shell_escape(stderr_file)}
    status=$?
    MN_EXIT_CODE="$status" /usr/bin/python3 - <<'PY'
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
    #{cleanup_step}
    exit "$status"
    """

    if byte_size(actual_command) > max_command_length() do
      {:error, "command exceeds MN_MAX_COMMAND_LENGTH"}
    else
      {:ok, ["bash", "-lc", wrapper]}
    end
  end

  defp max_command_length do
    Config.integer("MN_MAX_COMMAND_LENGTH", :max_command_length)
  end

  defp run_command(executable, args) do
    {output, exit_code} =
      System.cmd(executable, args,
        stderr_to_stdout: true,
        env: OpenShellCLI.command_env()
      )

    {:ok, output, exit_code}
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  defp upload_workspace(executable, sandbox_name, staged_dir, remote_dir) do
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

  defp run_ssh_command(config, sandbox_name, ssh_host, command) do
    executable = sandbox_cli(config)

    case OpenShellCLI.direct_exec_args(sandbox_name, command) do
      nil -> run_registered_gateway_ssh(config, executable, sandbox_name, ssh_host, command)
      args -> OpenShellCLI.run_with_closed_stdin(executable, args)
    end
  end

  defp run_registered_gateway_ssh(config, executable, sandbox_name, ssh_host, command) do
    ssh_bin = Map.get(config, "ssh_bin", "ssh")

    temp_config =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_ssh_#{System.unique_integer([:positive])}"
      )

    try do
      case System.cmd(executable, ["sandbox", "ssh-config", sandbox_name],
             stderr_to_stdout: true,
             env: OpenShellCLI.command_env()
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
           %{
             "sandbox_name" => sandbox_name,
             "remote_dir" => remote_dir,
             "exit_code" => parsed["exit_code"],
             "openshell_exit_code" => openshell_exit_code,
             "stdout" => parsed["stdout"],
             "stderr" => parsed["stderr"],
             "logs" => logs,
             "raw_output" => output
           }
           |> sanitize_result()
           |> maybe_put_cleanup_warning(parsed["exit_code"], openshell_exit_code, logs)}
        else
          {:error, error} -> {:error, Exception.message(error)}
        end

      _ ->
        {:ok,
         %{
           "sandbox_name" => sandbox_name,
           "remote_dir" => remote_dir,
           "exit_code" => openshell_exit_code,
           "openshell_exit_code" => openshell_exit_code,
           "stdout" => "",
           "stderr" => "",
           "logs" => String.trim(output),
           "raw_output" => output
         }
         |> sanitize_result()
         |> maybe_put_cleanup_warning(
           openshell_exit_code,
           openshell_exit_code,
           String.trim(output)
         )}
    end
  end

  defp sanitize_result(result) do
    MirrorNeuron.Runner.Result.sanitize(result)
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
        Config.string("MN_TEMP_DIR", :temp_dir),
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

  defp resolve_local_cli_paths(config, opts) do
    payloads_path =
      Keyword.get(opts, :payloads_path) ||
        Map.get(config, "__payloads_path") ||
        Map.get(config, :__payloads_path)

    config
    |> maybe_promote_custom_openshell_image()
    |> resolve_from_path(payloads_path)
    |> resolve_policy_path(payloads_path)
    |> resolve_local_cli_path("ssh_key", payloads_path)
  end

  defp maybe_promote_custom_openshell_image(config) do
    cond do
      Map.get(config, "from") not in [nil, ""] ->
        config

      is_binary(Map.get(config, "custom_openshell_image")) ->
        Map.put(config, "from", Map.get(config, "custom_openshell_image"))

      true ->
        config
    end
  end

  defp resolve_from_path(config, nil), do: config

  defp resolve_from_path(config, payloads_path) do
    case Map.get(config, "from") do
      nil ->
        config

      value when is_binary(value) ->
        resolved =
          if Path.type(value) == :absolute do
            value
          else
            Path.expand(value, payloads_path)
          end

        if File.exists?(resolved) do
          Map.put(config, "from", resolved)
        else
          config
        end

      _other ->
        config
    end
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

  defp resolve_policy_path(config, nil), do: config

  defp resolve_policy_path(config, payloads_path) do
    config
    |> resolve_local_cli_path("policy", payloads_path)
    |> maybe_prepare_policy_runtime_filesystem()
  end

  defp maybe_prepare_policy_runtime_filesystem(%{"policy" => policy_path} = config)
       when is_binary(policy_path) do
    Map.put(config, "policy", prepare_policy_runtime_filesystem(policy_path))
  end

  defp maybe_prepare_policy_runtime_filesystem(config), do: config

  defp prepare_policy_runtime_filesystem(policy_path) do
    case File.read(policy_path) do
      {:ok, text} ->
        cond do
          String.contains?(text, "/dev/null") ->
            policy_path

          String.contains?(text, "filesystem_policy:") ->
            policy_path

          true ->
            write_runtime_policy(policy_path, append_runtime_filesystem_policy(text))
        end

      {:error, _reason} ->
        policy_path
    end
  end

  defp append_runtime_filesystem_policy(text) do
    String.trim_trailing(text) <> "\n\n" <> runtime_filesystem_policy()
  end

  defp runtime_filesystem_policy do
    """
    filesystem_policy:
      include_workdir: true
      read_only:
        - /usr
        - /lib
        - /etc
        - /var/log
        - /proc
        - /dev/urandom
      read_write:
        - /sandbox
        - /tmp
        - /dev/null
    """
  end

  defp write_runtime_policy(source_path, text) do
    digest =
      :crypto.hash(:sha256, source_path <> "\0" <> text)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    policy_dir =
      Path.join(Config.string("MN_TEMP_DIR", :temp_dir), "mirror_neuron_openshell_policies")

    File.mkdir_p!(policy_dir)
    target = Path.join(policy_dir, "#{digest}.yaml")
    File.write!(target, text)
    target
  end

  defp build_sandbox_name(config, opts) do
    prefix = Map.get(config, "name_prefix", "mirror-neuron")
    job_id = Keyword.get(opts, :job_id, "job")
    agent_id = Keyword.get(opts, :agent_id, "agent")
    attempt = Keyword.get(opts, :attempt, 1)
    invocation = Keyword.get(opts, :invocation, 1)

    sanitized_base =
      [prefix, job_id, agent_id]
      |> Enum.join("-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    digest =
      [prefix, job_id, agent_id, to_string(invocation)]
      |> Enum.join("|")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 10)

    suffix = "#{digest}-i#{invocation}-a#{attempt}"
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
    invocation = Keyword.get(opts, :invocation, 1)
    unique = Integer.to_string(System.unique_integer([:positive]))

    if persistent_workspace?(config) do
      Path.join([root, "agents", agent])
    else
      Path.join([root, "runs", agent, "i#{invocation}-a#{attempt}-#{unique}"])
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
    Map.get(
      config,
      "sandbox_cli",
      Config.executable("MN_OPENSHELL_BIN", :openshell_bin)
    )
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

  defp put_uploads(args, staged_dir, remote_dir) do
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
