defmodule MirrorNeuron.Runner.HostLocal do
  alias MirrorNeuron.Message
  alias MirrorNeuron.Config

  @result_start "__MIRROR_NEURON_RESULT_START__"
  @result_end "__MIRROR_NEURON_RESULT_END__"

  def run(payload, config, opts \\ []) do
    runner_name = build_runner_name(config, opts)

    base_dir =
      Path.join(
        Config.string("MIRROR_NEURON_TEMP_DIR", :temp_dir),
        "mirror_neuron_host_local_#{runner_name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    message = build_message(payload, config, opts)

    try do
      with :ok <- copy_uploads(base_dir, config, opts),
           :ok <- write_runtime_files(base_dir, message, opts),
           {command, env, workdir} <- build_command(config, base_dir, opts, message),
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

  defp build_command(config, base_dir, opts, message) do
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
      |> Enum.map(fn {key, value} -> {key, value} end)

    command_size = command_size(configured_command)

    if command_size > max_command_length() do
      {:error, "command exceeds MIRROR_NEURON_MAX_COMMAND_LENGTH"}
    else
      {normalize_command(configured_command), env, workdir}
    end
  end

  defp max_command_length do
    System.get_env("MIRROR_NEURON_MAX_COMMAND_LENGTH", "32768")
    |> String.to_integer()
  end

  defp command_size(command) when is_binary(command), do: byte_size(command)
  defp command_size(command) when is_list(command), do: command |> Enum.join("\0") |> byte_size()

  defp normalize_command(command) when is_list(command), do: command

  defp normalize_command(command) when is_binary(command) do
    stdout_file = "mirror_neuron_stdout.txt"
    stderr_file = "mirror_neuron_stderr.txt"

    wrapper = """
    set +e
    #{command} >#{shell_escape(stdout_file)} 2>#{shell_escape(stderr_file)}
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

    ["bash", "-lc", wrapper]
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
      _ -> System.get_env("MIRROR_NEURON_MAX_ARTIFACT_BYTES", "1048576") |> String.to_integer()
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
      System.get_env("MIRROR_NEURON_MAX_ARTIFACT_BYTES", "1048576")
      |> String.to_integer()

    if byte_size(text) > max_bytes do
      binary_part(text, 0, max_bytes) <> "\n[truncated by MIRROR_NEURON_MAX_ARTIFACT_BYTES]"
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
      "MIRROR_NEURON_INPUT_FILE" => input_file,
      "MIRROR_NEURON_CONTEXT_FILE" => context_file,
      "MIRROR_NEURON_MESSAGE_FILE" => message_file,
      "MIRROR_NEURON_BODY_FILE" => body_file,
      "MIRROR_NEURON_BODY_CONTENT_TYPE" => Message.content_type(message),
      "MIRROR_NEURON_BODY_CONTENT_ENCODING" => Message.content_encoding(message),
      "MIRROR_NEURON_AGENT_TYPE" => to_string(Keyword.get(opts, :agent_type, "")),
      "MIRROR_NEURON_AGENT_TEMPLATE" => Keyword.get(opts, :template_type, "generic"),
      "MIRROR_NEURON_JOB_ID" => to_string(Keyword.get(opts, :job_id, "")),
      "MIRROR_NEURON_AGENT_ID" => to_string(Keyword.get(opts, :agent_id, "")),
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
