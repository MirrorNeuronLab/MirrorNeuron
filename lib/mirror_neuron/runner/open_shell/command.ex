defmodule MirrorNeuron.Runner.OpenShell.Command do
  @moduledoc "Builds sandbox CLI arguments and quoted supervised worker commands."

  alias MirrorNeuron.Config
  alias MirrorNeuron.Message
  alias MirrorNeuron.Runner.OpenShell.Settings
  alias MirrorNeuron.Runner.OpenShell.Uploads
  alias MirrorNeuron.Runner.OpenShell.Workspace

  @result_start "__MN_RESULT_START__"
  @result_end "__MN_RESULT_END__"

  def build_args(sandbox_name, staged_dir, remote_dir, config, opts) do
    with {:ok, command} <- build_command(config, remote_dir, opts) do
      args =
        [
          "sandbox",
          "create",
          "--name",
          sandbox_name,
          "--no-git-ignore"
        ]
        |> Uploads.put_uploads(staged_dir, remote_dir)
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

  def build_command(config, remote_dir, opts) do
    workdir = Settings.resolve_workdir(config, remote_dir)
    input_file = Path.join(remote_dir, "mirror_neuron_input.json")
    context_file = Path.join(remote_dir, "mirror_neuron_context.json")
    message_file = Path.join(remote_dir, "mirror_neuron_message.json")
    body_file = Path.join(remote_dir, "mirror_neuron_body.bin")
    stdout_file = Path.join(remote_dir, "mirror_neuron_stdout.txt")
    stderr_file = Path.join(remote_dir, "mirror_neuron_stderr.txt")
    message = Workspace.build_message(%{}, config, opts)

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

    cleanup_remote_dir = Settings.cleanup_remote_dir?(config)

    cleanup_step =
      if cleanup_remote_dir do
        "rm -rf #{shell_escape(remote_dir)} || true"
      else
        ":"
      end

    supervision_spec =
      Jason.encode!(%{
        "command" => actual_command,
        "workdir" => workdir,
        "timeout_seconds" => Map.get(config, "timeout_seconds", 600),
        "max_result_bytes" => Map.get(config, "max_output_bytes", 1_000_000),
        "stdout_path" => stdout_file,
        "stderr_path" => stderr_file
      })

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
    export MN_AGENT_BEACON_STDOUT_PREFIX=__MN_AGENT_BEACON__
    /usr/bin/python3 #{shell_escape(Path.join(remote_dir, "mirror_neuron_supervision.py"))} <<'MN_SUPERVISION'
    #{supervision_spec}
    MN_SUPERVISION
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
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp max_command_length do
    Config.integer("MN_MAX_COMMAND_LENGTH", :max_command_length)
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
    name = key |> to_string() |> String.trim()

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) do
      name
    else
      raise ArgumentError, "invalid environment variable name: #{inspect(name)}"
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

  defp substitute(command, substitutions) do
    Enum.reduce(substitutions, command, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp shell_escape(value) do
    "'#{String.replace(to_string(value), "'", "'\"'\"'")}'"
  end
end
