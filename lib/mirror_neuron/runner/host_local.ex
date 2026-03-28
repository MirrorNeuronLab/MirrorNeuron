defmodule MirrorNeuron.Runner.HostLocal do
  alias MirrorNeuron.Message

  @result_start "__MIRROR_NEURON_RESULT_START__"
  @result_end "__MIRROR_NEURON_RESULT_END__"

  def run(payload, config, opts \\ []) do
    runner_name = build_runner_name(config, opts)
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_#{runner_name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    message = build_message(payload, config, opts)

    try do
      with :ok <- copy_uploads(base_dir, config, opts),
           :ok <- write_runtime_files(base_dir, message, opts),
           {command, env, workdir} <- build_command(config, base_dir, opts, message),
           {:ok, output, exit_code} <- run_command(command, env, workdir),
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
    with :ok <- File.write(Path.join(base_dir, "mirror_neuron_input.json"), Jason.encode!(Message.body(message), pretty: true)),
         :ok <- File.write(Path.join(base_dir, "mirror_neuron_message.json"), Jason.encode!(message, pretty: true)),
         {:ok, body_binary} <- Message.body_binary(message),
         :ok <- File.write(Path.join(base_dir, "mirror_neuron_body.bin"), body_binary),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_context.json"),
             Jason.encode!(
               %{
                 job_id: Keyword.get(opts, :job_id),
                 agent_id: Keyword.get(opts, :agent_id),
                 timestamp: MirrorNeuron.Runtime.timestamp()
               },
               pretty: true
             )
           ) do
      :ok
    end
  end

  defp build_command(config, base_dir, opts, message) do
    workdir = resolve_workdir(config, base_dir)
    input_file = Path.join(base_dir, "mirror_neuron_input.json")
    context_file = Path.join(base_dir, "mirror_neuron_context.json")
    message_file = Path.join(base_dir, "mirror_neuron_message.json")
    body_file = Path.join(base_dir, "mirror_neuron_body.bin")
    stdout_file = Path.join(base_dir, "mirror_neuron_stdout.txt")
    stderr_file = Path.join(base_dir, "mirror_neuron_stderr.txt")

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
          "python3 - <<'PY'\nprint('No command configured for host-local worker')\nPY"

        command when is_binary(command) ->
          substitute(command, substitutions)

        command when is_list(command) ->
          command
          |> Enum.map(&substitute(to_string(&1), substitutions))
          |> Enum.map(&shell_escape/1)
          |> Enum.join(" ")
      end

    wrapper = """
    set +e
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
    exit "$status"
    """

    env =
      runtime_env(input_file, context_file, message_file, body_file, workdir, message)
      |> Map.merge(extra_env(config))
      |> Enum.map(fn {key, value} -> {key, value} end)

    {["bash", "-lc", wrapper], env, workdir}
  end

  defp run_command([command | args], env, workdir) do
    {output, exit_code} =
      System.cmd(command, args, cd: workdir, env: env, stderr_to_stdout: true)

    {:ok, output, exit_code}
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{command}: #{Exception.message(error)}"}
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
           %{
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
           }}
        else
          {:error, error} -> {:error, Exception.message(error)}
        end

      _ ->
        {:ok,
         %{
           "sandbox_name" => runner_name,
           "remote_dir" => workdir,
           "exit_code" => runner_exit_code,
           "runner_exit_code" => runner_exit_code,
           "stdout" => "",
           "stderr" => "",
           "logs" => String.trim(output),
           "raw_output" => output,
           "runner" => "host_local",
           "node_name" => to_string(Node.self())
         }}
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

  defp runtime_env(input_file, context_file, message_file, body_file, workdir, message) do
    %{
      "MIRROR_NEURON_INPUT_FILE" => input_file,
      "MIRROR_NEURON_CONTEXT_FILE" => context_file,
      "MIRROR_NEURON_MESSAGE_FILE" => message_file,
      "MIRROR_NEURON_BODY_FILE" => body_file,
      "MIRROR_NEURON_BODY_CONTENT_TYPE" => Message.content_type(message),
      "MIRROR_NEURON_BODY_CONTENT_ENCODING" => Message.content_encoding(message),
      "MIRROR_NEURON_WORKDIR" => workdir
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
