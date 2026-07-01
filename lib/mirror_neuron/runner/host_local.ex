defmodule MirrorNeuron.Runner.HostLocal do
  alias MirrorNeuron.Message
  alias MirrorNeuron.Config

  @result_start "__MN_RESULT_START__"
  @result_end "__MN_RESULT_END__"
  @beacon_prefix "__MN_AGENT_BEACON__"
  @default_beacon_interval_ms 15_000
  @default_beacon_timeout_ms 45_000

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
           {:ok, output, exit_code} <- run_command(command, env, workdir, config, opts, message),
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
                 workflow: workflow_context(message),
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
          "python3.11 - <<'PY'\nprint('No command configured for host-local worker')\nPY"

        command when is_binary(command) ->
          substitute(command, substitutions)

        command when is_list(command) ->
          command
          |> Enum.map(&substitute(to_string(&1), substitutions))
      end

    env =
      runtime_env(input_file, context_file, message_file, body_file, workdir, message, opts)
      |> Map.merge(beacon_env(config, opts, message))
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
    MN_EXIT_CODE="$status" python3.11 - <<'PY'
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
    if Path.basename(executable) in ["python", "python3", "python3.11"] do
      [python | args]
    else
      [executable | args]
    end
  end

  defp run_command([command | args], env, workdir, config, opts, message) do
    executable = System.find_executable(command) || command
    max_output_bytes = max_output_bytes(config)
    timeout_ms = timeout_ms(config)
    deadline = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms
    beacon_state = beacon_state(config, opts, message)

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

    beacon_state = emit_runtime_beacon(beacon_state, "started")
    collect_port_output(port, [], 0, max_output_bytes, deadline, beacon_state)
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{command}: #{Exception.message(error)}"}
  end

  defp collect_port_output(port, chunks, bytes, max_output_bytes, deadline, beacon_state) do
    timeout = receive_timeout(deadline, beacon_state)

    receive do
      {^port, {:data, data}} ->
        now = now_ms()
        {clean_data, next_beacon_state} = filter_beacon_output(data, beacon_state)
        next_beacon_state = maybe_emit_runtime_beacon(next_beacon_state, now)
        {next_chunks, next_bytes} = append_output(chunks, bytes, clean_data, max_output_bytes)

        collect_port_output(
          port,
          next_chunks,
          next_bytes,
          max_output_bytes,
          deadline,
          next_beacon_state
        )

      {^port, {:exit_status, exit_code}} ->
        {tail, next_beacon_state} = flush_beacon_buffer(beacon_state)
        {next_chunks, _next_bytes} = append_output(chunks, bytes, tail, max_output_bytes)
        _ = emit_runtime_beacon(next_beacon_state, "completed")
        {:ok, next_chunks |> Enum.reverse() |> IO.iodata_to_binary(), exit_code}
    after
      timeout ->
        now = now_ms()

        cond do
          deadline && now >= deadline ->
            Port.close(port)

            {:error,
             %{
               "error" => "host local command timed out",
               "timeout_ms" => max(timeout || 0, 0),
               "stdout" => chunks |> Enum.reverse() |> IO.iodata_to_binary()
             }}

          beacon_missed?(beacon_state, now) ->
            Port.close(port)
            missed_payload = beacon_payload(beacon_state, "missed", "agent", now)
            emit_beacon_event(beacon_state, :agent_beacon_missed, missed_payload)

            {:error,
             %{
               "error" => "agent beacon deadline exceeded",
               "timeout_ms" => beacon_state.timeout_ms,
               "stdout" => chunks |> Enum.reverse() |> IO.iodata_to_binary(),
               "beacon" => missed_payload
             }}

          true ->
            next_beacon_state = maybe_emit_runtime_beacon(beacon_state, now)

            collect_port_output(
              port,
              chunks,
              bytes,
              max_output_bytes,
              deadline,
              next_beacon_state
            )
        end
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

  defp receive_timeout(deadline, beacon_state) do
    now = now_ms()

    [
      deadline,
      if(beacon_state.enabled, do: beacon_state.next_runtime_beacon_at),
      if(beacon_state.required, do: beacon_state.last_agent_beacon_at + beacon_state.timeout_ms)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> :infinity
      candidates -> max(Enum.min(candidates) - now, 0)
    end
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
      _ -> Config.integer("MN_MAX_ARTIFACT_BYTES", :max_artifact_bytes)
    end
  end

  defp beacon_env(config, opts, message) do
    if truthy?(Map.get(config, "beacon_enabled")) do
      interval_ms =
        positive_int(Map.get(config, "beacon_interval_ms"), @default_beacon_interval_ms)

      timeout_ms = positive_int(Map.get(config, "beacon_timeout_ms"), @default_beacon_timeout_ms)
      required = truthy?(Map.get(config, "agent_beacon_required"))
      environment = Map.get(config, "environment", %{})
      workflow = workflow_context(message)

      %{
        "MN_AGENT_BEACON_STDOUT_PREFIX" => beacon_prefix(config),
        "MN_AGENT_BEACON_INTERVAL_MS" => to_string(interval_ms),
        "MN_AGENT_BEACON_TIMEOUT_MS" => to_string(timeout_ms),
        "MN_AGENT_BEACON_REQUIRED" => if(required, do: "1", else: "0"),
        "MN_AGENT_BEACON_JOB_ID" => to_string(Keyword.get(opts, :job_id, "")),
        "MN_AGENT_BEACON_AGENT_ID" => to_string(Keyword.get(opts, :agent_id, "")),
        "MN_AGENT_BEACON_ATTEMPT" =>
          to_string(Map.get(workflow, "attempt") || Keyword.get(opts, :attempt, 1)),
        "MN_AGENT_BEACON_STEP" =>
          to_string(
            Map.get(workflow, "step_id") ||
              Map.get(environment, "MN_WORKFLOW_STEP_ID") ||
              Keyword.get(opts, :agent_id, "")
          ),
        "MN_AGENT_BEACON_SOURCE" => "agent"
      }
    else
      %{}
    end
  end

  defp beacon_state(config, opts, message) do
    now = now_ms()
    interval_ms = positive_int(Map.get(config, "beacon_interval_ms"), @default_beacon_interval_ms)
    timeout_ms = positive_int(Map.get(config, "beacon_timeout_ms"), @default_beacon_timeout_ms)
    environment = Map.get(config, "environment", %{})
    workflow = workflow_context(message)

    %{
      enabled: truthy?(Map.get(config, "beacon_enabled")),
      required: truthy?(Map.get(config, "agent_beacon_required")),
      interval_ms: interval_ms,
      timeout_ms: timeout_ms,
      prefix: beacon_prefix(config),
      event_prefix: agent_event_prefix(config),
      line_buffer: "",
      sequence: 0,
      job_id: to_string(Keyword.get(opts, :job_id, "")),
      agent_id: to_string(Keyword.get(opts, :agent_id, "")),
      step:
        to_string(
          Map.get(workflow, "step_id") ||
            Map.get(environment, "MN_WORKFLOW_STEP_ID") ||
            Keyword.get(opts, :agent_id, "")
        ),
      attempt: Map.get(workflow, "attempt") || Keyword.get(opts, :attempt, 1),
      event_callback: Keyword.get(opts, :event_callback),
      started_at: now,
      last_agent_beacon_at: now,
      next_runtime_beacon_at: now + interval_ms
    }
  end

  defp beacon_prefix(config) do
    case Map.get(config, "agent_beacon_stdout_prefix") do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> @beacon_prefix
    end
  end

  defp agent_event_prefix(config) do
    case Map.get(config, "agent_event_stdout_prefix") do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> "__MN_EVENT__"
    end
  end

  defp filter_beacon_output(data, state) do
    combined = state.line_buffer <> data
    parts = :binary.split(combined, "\n", [:global])
    complete_count = length(parts) - 1
    complete_lines = Enum.take(parts, complete_count)
    trailing = List.last(parts) || ""

    {clean_lines, next_state} =
      Enum.reduce(complete_lines, {[], %{state | line_buffer: trailing}}, fn line,
                                                                             {acc, current_state} ->
        line = String.trim_trailing(line, "\r")

        cond do
          String.starts_with?(line, current_state.event_prefix) ->
            {"", parsed_state} = handle_agent_event_line(line, current_state)
            {acc, parsed_state}

          String.starts_with?(line, current_state.prefix) ->
            {"", parsed_state} = handle_agent_beacon_line(line, current_state)
            {acc, parsed_state}

          true ->
            {[line | acc], current_state}
        end
      end)

    clean_output =
      clean_lines
      |> Enum.reverse()
      |> Enum.map(&(&1 <> "\n"))
      |> IO.iodata_to_binary()

    {clean_output, next_state}
  end

  defp flush_beacon_buffer(%{enabled: false, line_buffer: buffer} = state),
    do: {buffer, %{state | line_buffer: ""}}

  defp flush_beacon_buffer(%{line_buffer: ""} = state), do: {"", state}

  defp flush_beacon_buffer(state) do
    line = String.trim_trailing(state.line_buffer, "\r")

    cond do
      String.starts_with?(line, state.event_prefix) ->
        {"", next_state} = handle_agent_event_line(line, state)
        {"", %{next_state | line_buffer: ""}}

      String.starts_with?(line, state.prefix) ->
        {"", next_state} = handle_agent_beacon_line(line, state)
        {"", %{next_state | line_buffer: ""}}

      true ->
        {state.line_buffer, %{state | line_buffer: ""}}
    end
  end

  defp handle_agent_event_line(line, state) do
    raw_payload =
      line
      |> String.replace_prefix(state.event_prefix, "")
      |> String.trim()

    case Jason.decode(raw_payload) do
      {:ok, %{"type" => event_type, "payload" => payload}}
      when is_binary(event_type) and is_map(payload) ->
        emit_beacon_event(state, event_type, agent_event_payload(state, payload))

      {:ok, payload} when is_map(payload) ->
        event_type = Map.get(payload, "type", "agent_activity")

        emit_beacon_event(
          state,
          to_string(event_type),
          agent_event_payload(state, Map.drop(payload, ["type"]))
        )

      _ ->
        emit_beacon_event(
          state,
          "agent_activity",
          agent_event_payload(state, %{"message" => raw_payload, "category" => "agent"})
        )
    end

    {"", state}
  end

  defp handle_agent_beacon_line(line, state) do
    raw_payload =
      line
      |> String.replace_prefix(state.prefix, "")
      |> String.trim()

    decoded =
      case Jason.decode(raw_payload) do
        {:ok, payload} when is_map(payload) -> payload
        _ -> %{"message" => raw_payload}
      end

    now = now_ms()

    payload =
      beacon_payload(
        state,
        Map.get(decoded, "status", "working"),
        Map.get(decoded, "source", "agent"),
        now,
        decoded
      )

    emit_beacon_event(state, :agent_beacon, payload)
    {"", %{state | sequence: state.sequence + 1, last_agent_beacon_at: now}}
  end

  defp maybe_emit_runtime_beacon(%{enabled: false} = state, _now), do: state

  defp maybe_emit_runtime_beacon(state, now) do
    if now >= state.next_runtime_beacon_at do
      state
      |> emit_runtime_beacon("working", now)
      |> Map.update!(
        :next_runtime_beacon_at,
        &max(&1 + state.interval_ms, now + state.interval_ms)
      )
    else
      state
    end
  end

  defp emit_runtime_beacon(state, status, now \\ now_ms())

  defp emit_runtime_beacon(%{enabled: false} = state, _status, _now), do: state

  defp emit_runtime_beacon(state, status, now) do
    payload = beacon_payload(state, status, "runtime", now)
    emit_beacon_event(state, :agent_beacon, payload)
    %{state | sequence: state.sequence + 1}
  end

  defp beacon_payload(state, status, source, now, extra \\ %{}) do
    Map.merge(
      %{
        "schema" => "mn.agent.beacon.v1",
        "job_id" => state.job_id,
        "agent_id" => state.agent_id,
        "step" => state.step,
        "attempt" => state.attempt,
        "source" => source,
        "status" => status,
        "sequence" => state.sequence,
        "message" => Map.get(extra, "message", default_beacon_message(source, status)),
        "interval_ms" => state.interval_ms,
        "timeout_ms" => state.timeout_ms,
        "elapsed_ms" => max(now - state.started_at, 0),
        "ms_since_last_agent_beacon" => max(now - state.last_agent_beacon_at, 0),
        "emitted_at" => MirrorNeuron.Runtime.timestamp()
      },
      Map.drop(extra, [
        "schema",
        "job_id",
        "agent_id",
        "step",
        "attempt",
        "source",
        "status",
        "sequence",
        "interval_ms",
        "timeout_ms",
        "elapsed_ms",
        "ms_since_last_agent_beacon",
        "emitted_at"
      ])
    )
  end

  defp agent_event_payload(state, payload) do
    Map.merge(
      %{
        "schema" => "mn.agent.activity.v1",
        "job_id" => state.job_id,
        "agent_id" => state.agent_id,
        "step" => state.step,
        "step_id" => state.step,
        "attempt" => state.attempt,
        "source" => "agent",
        "category" => Map.get(payload, "category", "agent"),
        "emitted_at" => MirrorNeuron.Runtime.timestamp()
      },
      Map.drop(payload, [
        "schema",
        "job_id",
        "agent_id",
        "step",
        "step_id",
        "attempt",
        "source",
        "emitted_at"
      ])
    )
  end

  defp default_beacon_message("runtime", "started"), do: "HostLocal command started"
  defp default_beacon_message("runtime", "completed"), do: "HostLocal command completed"
  defp default_beacon_message("runtime", _status), do: "HostLocal command is still running"
  defp default_beacon_message("agent", "missed"), do: "Agent beacon deadline exceeded"
  defp default_beacon_message("agent", _status), do: "Agent is still working"
  defp default_beacon_message(_source, _status), do: "Worker is still running"

  defp emit_beacon_event(%{event_callback: callback}, event_type, payload)
       when is_function(callback, 2) do
    callback.(event_type, payload)
  end

  defp emit_beacon_event(_state, _event_type, _payload), do: :ok

  defp beacon_missed?(%{enabled: true, required: true} = state, now) do
    now - state.last_agent_beacon_at >= state.timeout_ms
  end

  defp beacon_missed?(_state, _now), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp truthy?(value), do: value in [true, "true", "1", "yes"]

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
    MirrorNeuron.Runner.Result.sanitize(result)
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
        copy_upload_entry(source, target, coordinator_node, config, opts)
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_upload_entry(source, target, coordinator_node, config, opts) do
    is_local = coordinator_node == Node.self()

    artifact_result =
      MirrorNeuron.Runner.Uploads.materialize_artifacts(source, target, config, opts)

    cond do
      is_local and File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp_r(source, target)
        |> case do
          {:ok, _files} -> artifact_upload_result(artifact_result)
          {:error, reason, _file} -> {:halt, {:error, inspect(reason)}}
        end

      is_local and File.exists?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp(source, target)
        |> case do
          :ok -> artifact_upload_result(artifact_result)
          {:error, reason} -> {:halt, {:error, inspect(reason)}}
        end

      not is_local ->
        case copy_remote_upload(source, target, coordinator_node) do
          {:cont, :ok} -> artifact_upload_result(artifact_result)
          {:halt, {:error, _reason}} when artifact_result == :ok -> {:cont, :ok}
          other -> other
        end

      artifact_result == :ok ->
        {:cont, :ok}

      match?({:error, _reason}, artifact_result) ->
        {:error, reason} = artifact_result
        {:halt, {:error, reason}}

      true ->
        {:halt, {:error, "upload source does not exist locally: #{source}"}}
    end
  end

  defp artifact_upload_result(:ok), do: {:cont, :ok}
  defp artifact_upload_result(:not_found), do: {:cont, :ok}
  defp artifact_upload_result({:error, reason}), do: {:halt, {:error, reason}}

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
      do_list_all_files(dir, dir)
      |> Enum.sort()
    else
      []
    end
  end

  defp do_list_all_files(root, dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      cond do
        File.dir?(path) -> do_list_all_files(root, path)
        File.regular?(path) -> [Path.relative_to(path, root)]
        true -> []
      end
    end)
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
        spec -> prepared_or_legacy_python_environment(config, spec)
      end
    end
  end

  defp prepared_or_legacy_python_environment(config, spec) do
    cond do
      native_prep_enabled?() ->
        ensure_cached_python_environment(spec)

      prepared_python_env = prepared_python_environment(config) ->
        {:ok, prepared_python_env}

      true ->
        {:error,
         "python_environment preparation is owned by mn-python-sdk/API/CLI; prepare the environment before submission and provide python_environment.path, MN_PYTHON_ENV, or VIRTUAL_ENV"}
    end
  end

  defp prepared_python_environment(config) do
    env = extra_env(config)

    dir =
      get_in(config, ["python_environment", "path"]) ||
        get_in(config, ["python_environment", "prepared_path"]) ||
        Map.get(env, "MN_PYTHON_ENV") ||
        Map.get(env, "VIRTUAL_ENV")

    if is_binary(dir) and dir != "" do
      python_environment(Path.expand(dir))
    end
  end

  defp native_prep_enabled? do
    System.get_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP")
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
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
    ["python3.11", "python3", "python"]
    |> Enum.map(&System.find_executable/1)
    |> Enum.find(&python_3_11?/1) || "python3.11"
  end

  defp python_3_11?(nil), do: false

  defp python_3_11?(python) do
    case python_version(python) do
      {:ok, "Python 3.11" <> _} -> true
      _ -> false
    end
  end

  defp python_environment_cache_root do
    Config.optional_string("MN_BLUEPRINT_PYTHON_ENVS_DIR", :blueprint_python_envs_dir) ||
      Path.join(Config.string("MN_TEMP_DIR", :temp_dir), "blueprint_python_envs")
  end

  defp python_environment_setup_timeout_ms do
    Config.integer(
      "MN_BLUEPRINT_PYTHON_ENV_SETUP_TIMEOUT_MS",
      :blueprint_python_env_setup_timeout_ms
    )
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
    MirrorNeuron.SafeAccess.map_get(config, key)
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
    |> Map.merge(workflow_env(message))
  end

  defp workflow_env(message) do
    workflow = workflow_context(message)

    %{
      "MN_WORKFLOW_RUN_ID" => Map.get(workflow, "run_id"),
      "MN_WORKFLOW_STEP_ID" => Map.get(workflow, "step_id"),
      "MN_WORKFLOW_ATTEMPT_ID" => Map.get(workflow, "attempt_id"),
      "MN_WORKFLOW_ATTEMPT" => Map.get(workflow, "attempt"),
      "MN_WORKFLOW_DEADLINE_AT" => Map.get(workflow, "deadline_at"),
      "MN_WORKFLOW_HEARTBEAT_DEADLINE_AT" => Map.get(workflow, "heartbeat_deadline_at"),
      "MN_WORKFLOW_IDEMPOTENCY_KEY" => Map.get(workflow, "idempotency_key")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end

  defp workflow_context(message) do
    headers = Message.headers(message)

    %{
      "run_id" => Map.get(headers, "mn.workflow.run_id"),
      "step_id" => Map.get(headers, "mn.workflow.step_id"),
      "attempt_id" => Map.get(headers, "mn.workflow.attempt_id"),
      "attempt" => Map.get(headers, "mn.workflow.attempt"),
      "deadline_at" => Map.get(headers, "mn.workflow.deadline_at"),
      "heartbeat_deadline_at" => Map.get(headers, "mn.workflow.heartbeat_deadline_at"),
      "idempotency_key" => Map.get(headers, "mn.workflow.idempotency_key")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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
