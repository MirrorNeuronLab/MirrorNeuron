defmodule MirrorNeuron.Runner.HostLocal.Command do
  @moduledoc "Builds commands, applies prepared Python interpreters and resolves executable paths."

  alias MirrorNeuron.Runner.HostLocal.Beacons
  alias MirrorNeuron.Config
  alias MirrorNeuron.Runner.HostLocal.Context
  alias MirrorNeuron.Runner.HostLocal.Paths
  alias MirrorNeuron.Runner.HostLocal.PythonEnvironment
  alias MirrorNeuron.Runner.WorkflowEnvironment

  @result_start "__MN_RESULT_START__"
  @result_end "__MN_RESULT_END__"

  def build_command(config, base_dir, opts, message, python_env) do
    workdir = Paths.resolve_workdir(config, base_dir)
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
          "python3.12 - <<'PY'\nprint('No command configured for host-local worker')\nPY"

        command when is_binary(command) ->
          substitute(command, substitutions)

        command when is_list(command) ->
          command
          |> Enum.map(&substitute(to_string(&1), substitutions))
      end

    env =
      Context.runtime_env(
        input_file,
        context_file,
        message_file,
        body_file,
        workdir,
        message,
        opts
      )
      |> Map.merge(Beacons.beacon_env(config, opts, message))
      |> Map.merge(Context.extra_env(config))
      |> Map.merge(bundle_environment(base_dir))
      |> Map.merge(WorkflowEnvironment.from_options(Keyword.put(opts, :message, message)))
      |> PythonEnvironment.apply_python_environment_env(python_env)
      |> Enum.map(fn {key, value} -> {key, value} end)

    command_size = command_size(configured_command)

    if command_size > max_command_length() do
      {:error, "command exceeds MN_MAX_COMMAND_LENGTH"}
    else
      {normalize_command(configured_command, python_env), env, workdir}
    end
  end

  # These paths identify the invocation copy, never an inherited SDK/image or
  # submitter path. Installed SDK handlers cannot discover it from __file__.

  defp bundle_environment(base_dir) do
    %{
      "MN_BUNDLE_ROOT" => base_dir,
      "MN_BLUEPRINT_MANIFEST_PATH" => Path.join([base_dir, "runtime", "manifest.json"])
    }
  end

  defp max_command_length do
    Config.integer("MN_MAX_COMMAND_LENGTH", :max_command_length)
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
    (
    #{command}
    ) >#{shell_escape(stdout_file)} 2>#{shell_escape(stderr_file)}
    status=$?
    MN_EXIT_CODE="$status" python3.12 - <<'PY'
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

  defp rewrite_python_command([executable | args], %{python: python} = python_env) do
    cond do
      Path.basename(executable) in ["python", "python3", "python3.12"] ->
        [python | args]

      console_script = python_console_script(executable, python_env) ->
        [python, console_script | args]

      true ->
        [executable | args]
    end
  end

  defp python_console_script(executable, %{bin: bin}) do
    if executable == Path.basename(executable) do
      candidate = Path.join(bin, executable)

      with true <- File.regular?(candidate),
           {:ok, shebang} when is_binary(shebang) <-
             File.open(candidate, [:read], &IO.read(&1, :line)) do
        interpreter =
          shebang
          |> String.trim()
          |> String.trim_leading("#!")
          |> String.split()
          |> List.first()

        if is_binary(interpreter) and
             Path.basename(interpreter) in ["python", "python3", "python3.12"] do
          candidate
        end
      else
        _ -> nil
      end
    end
  end

  def resolve_executable(command, workdir, env) do
    find_executable_in_child_path(command, workdir, env) ||
      System.find_executable(command) ||
      case Path.expand(command, workdir) do
        candidate when candidate != command ->
          if File.exists?(candidate), do: candidate

        _candidate ->
          nil
      end
  end

  defp find_executable_in_child_path(command, workdir, env) do
    if Path.type(command) == :relative and Path.basename(command) == command do
      env
      |> Enum.find_value(fn
        {"PATH", path} when is_binary(path) -> executable_from_path(command, workdir, path)
        _entry -> nil
      end)
    end
  end

  defp executable_from_path(command, workdir, path) do
    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    path
    |> String.split(separator, trim: true)
    |> Enum.find_value(fn directory ->
      directory
      |> Path.join(command)
      |> Path.expand(workdir)
      |> System.find_executable()
    end)
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
