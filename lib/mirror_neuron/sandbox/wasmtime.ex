defmodule MirrorNeuron.Sandbox.Wasmtime do
  @moduledoc "A WASI command runs in a fresh Wasmtime process with a private invocation directory."

  alias MirrorNeuron.Runner.HostLocal.{Context, Execution}
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Sandbox.{WasmtimePayload, WitArtifacts, WitBroker, WitServices}

  @max_memory 268_435_456
  @max_output 1_048_576
  @max_seconds 900

  def validate(config) do
    case config["wasm_component"] do
      path when is_binary(path) ->
        if WasmtimePayload.relative?(path) and Path.extname(path) == ".wasm" do
          with :ok <- validate_settings(config),
               do: WitBroker.validate(Map.get(config, "wasm_capabilities", []))
        else
          {:error, "wasm_component must name a relative .wasm payload"}
        end

      _ ->
        {:error, "Wasmtime requires wasm_component"}
    end
  end

  defp validate_settings(config) do
    fields = Map.get(config, "wasm_config_fields", %{})

    if is_map(Map.get(config, "wasm_config", %{})) and is_map(fields) and
         Enum.all?(fields, fn {key, path} ->
           is_binary(key) and is_list(path) and path != [] and Enum.all?(path, &is_binary/1)
         end),
       do: :ok,
       else:
         {:error,
          "wasm_config must be an object and wasm_config_fields must map names to field paths"}
  end

  def run(payload, config, opts) do
    with :ok <- validate(config),
         executable when is_binary(executable) <- executable(config),
         {:ok, workspace} <- workspace() do
      try do
        invoke(executable, workspace, payload, config, opts)
      after
        File.rm_rf(workspace)
      end
    else
      nil -> {:error, "Wasmtime executable unavailable on this executor"}
      error -> error
    end
  end

  defp invoke(executable, workspace, payload, config, opts) do
    guest = Path.join(workspace, "job")
    component = Path.join(workspace, "agent.wasm")
    message = Context.build_message(payload, config, opts)

    with :ok <- File.mkdir(guest),
         :ok <- WasmtimePayload.stage(config["wasm_component"], component, config, opts),
         :ok <- check_header(component),
         :ok <- check_digest(component, config["wasm_component"]),
         :ok <- stage_inputs(guest, config, opts, message),
         :ok <- write_input(guest, message, opts),
         :ok <-
           File.write(
             Path.join(guest, "config.json"),
             Jason.encode!(guest_config(config))
           ) do
      timeout =
        limit(
          config["timeout_seconds"],
          if("approvals.request" in Map.get(config, "wasm_capabilities", []),
            do: 86_400,
            else: @max_seconds
          )
        )

      args = [
        executable,
        "run",
        "-C",
        "cache=n",
        "-S",
        "p3=y,inherit-env=n",
        "-S",
        "inherit-network=n,tcp=n,udp=n",
        "-S",
        "inherit-stdin=n",
        "-W",
        "max-memory-size=#{@max_memory}",
        "-W",
        "timeout=#{timeout}s",
        "--dir",
        guest <> "::/job",
        "--",
        component
      ]

      limits =
        config
        |> Map.put("timeout_seconds", timeout)
        |> Map.put("max_output_bytes", limit(config["max_output_bytes"], @max_output))

      execute = fn command ->
        Execution.run_command(
          command,
          [],
          workspace,
          limits,
          Keyword.merge(opts, bounded_command_output: true, wasm_guest: true),
          message
        )
      end

      result =
        case Map.fetch(config, "wasm_capabilities") do
          {:ok, grants} ->
            WitBroker.with_socket(
              grants,
              WitServices.dispatch(config, opts, message),
              fn socket ->
                execute.([executable, component, guest, socket])
              end
            )

          :error ->
            execute.(args)
        end

      with {:ok, output, status} <- result do
        result = %{
          "runner" => "wasmtime",
          "exit_code" => status,
          "runner_exit_code" => status,
          "stdout" => if(status == 0, do: String.trim(output), else: ""),
          "stderr" => if(status == 0, do: "", else: String.trim(output)),
          "node_name" => to_string(Node.self())
        }

        case {status, Jason.decode(output)} do
          {0, {:ok, decoded}} when is_map(decoded) ->
            # Only the graph owns routing and completion. Keep diagnostic
            # truncation separate from the data passed to the next step.
            cond do
              decoded["events"] not in [nil, []] or
                  Enum.any?(
                    ~w(emit_messages event_result next_state complete_run complete_step complete_job),
                    &Map.has_key?(decoded, &1)
                  ) ->
                {:error, "WASI commands return data through their declared workflow outputs"}

              MirrorNeuron.Builtins.Executor.Decoding.sdk_step_result?(decoded) ->
                structured = Map.take(decoded, ~w(outputs artifacts metrics status))

                {:ok,
                 result
                 |> MirrorNeuron.Runner.Result.sanitize()
                 |> Map.put("structured_result", structured)}

              true ->
                {:ok, MirrorNeuron.Runner.Result.sanitize(result)}
            end

          {0, _} ->
            {:ok, MirrorNeuron.Runner.Result.sanitize(result)}

          _ ->
            {:error, MirrorNeuron.Runner.Result.sanitize(result)}
        end
      end
    end
  end

  defp write_input(guest, message, opts) do
    workflow = Context.workflow_context(message)
    body = MirrorNeuron.Message.body(message)

    context = %{
      job_id: Keyword.get(opts, :job_id),
      agent_id: Keyword.get(opts, :agent_id),
      workflow: workflow
    }

    # Step sources emit their mapped fields in outputs. Child templates receive
    # their work packet directly from the ledger.
    with {:ok, input} <- mapped_input(body, workflow, opts),
         :ok <- File.write(Path.join(guest, "mirror_neuron_input.json"), Jason.encode!(input)),
         do: File.write(Path.join(guest, "mirror_neuron_context.json"), Jason.encode!(context))
  end

  defp mapped_input(%{"outputs" => value, "_mn_step" => _}, workflow, opts) do
    case StagedArtifact.output_ref(value) do
      nil ->
        {:ok, %{"step_input" => value}}

      ref ->
        with true <- ref["run_id"] == workflow["run_id"],
             owner = Keyword.get(opts, :coordinator_node, node()),
             {:ok, record} <-
               if(owner == node(),
                 do: MirrorNeuron.inspect_job(opts[:job_id]),
                 else: :rpc.call(owner, MirrorNeuron, :inspect_job, [opts[:job_id]])
               ),
             %{"submission_id" => id} <- MirrorNeuron.Artifacts.SharedStorage.run_data_ref(record),
             true <- ref["submission_id"] == id do
          {:ok, %{"step_input" => StagedArtifact.resolve!(ref)}}
        else
          _ -> {:error, :unbound_staged_step_input}
        end
    end
  end

  defp mapped_input(body, _, _), do: {:ok, body}

  defp stage_inputs(guest, config, opts, message) do
    case config["wasm_inputs"] do
      nil ->
        :ok

      path when is_binary(path) ->
        target = Path.join(guest, "inputs")

        workflow = Context.workflow_context(message)["run_id"]

        result =
          case WasmtimePayload.stage_run_inputs(path, target, workflow, opts) do
            :not_found -> WasmtimePayload.stage(path, target, config, opts)
            other -> other
          end

        case result do
          {:error, :enoent} = missing ->
            if config["wasm_optional_inputs"], do: File.mkdir_p(target), else: missing

          other ->
            other
        end

      _ ->
        {:error, "wasm_inputs must name a relative payload"}
    end
  end

  defp guest_config(config) do
    environment = config["environment"] || %{}

    resolved =
      case Jason.decode(environment["MN_BLUEPRINT_CONFIG_JSON"] || "{}") do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    # A component sees only the configuration fields explicitly mapped to it by
    # its blueprint. Runtime environment and credentials stay on the host.
    settings =
      Enum.reduce(config["wasm_config_fields"] || %{}, config["wasm_config"] || %{}, fn {key,
                                                                                         path},
                                                                                        acc ->
        case Enum.reduce(path, resolved, fn field, value -> if is_map(value), do: value[field] end) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    settings =
      Map.put(
        settings,
        "simulated_model",
        environment["MN_BLUEPRINT_FAKE_LLM"] == "1" or environment["MN_LLM_PROVIDER"] == "fake"
      )

    settings =
      case environment["MN_MAILBOX_ASSIGNMENT_ID"] do
        id when is_binary(id) and byte_size(id) in 1..256 ->
          Map.put(settings, "assignment_id", id)

        _ ->
          Map.delete(settings, "assignment_id")
      end

    case config["wasm_component"] do
      "wasm/composed/" <> file -> Map.put(settings, "component_sha256", Path.rootname(file))
      _ -> settings
    end
  end

  # Native/AOT artifacts must never reach the runtime's native-code loader.
  defp check_header(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 8)) do
      {:ok, <<0, "asm", 13, 0, 1, 0>>} -> :ok
      _ -> {:error, "expected a WebAssembly component binary"}
    end
  end

  defp limit(n, cap) when is_integer(n) and n > 0, do: min(n, cap)
  defp limit(_, cap), do: cap

  defp check_digest(component, "wasm/composed/" <> filename) do
    with {:ok, data} <- File.read(component),
         true <- filename == WitArtifacts.digest(data) <> ".wasm" do
      :ok
    else
      _ -> {:error, "Component differs from its submission digest"}
    end
  end

  defp check_digest(_, _), do: :ok

  defp executable(%{"wasm_capabilities" => _}) do
    System.find_executable(System.get_env("MN_WASMTIME_HOST_BIN") || "mn-wasmtime-runner")
  end

  defp executable(_) do
    System.find_executable(System.get_env("MN_WASMTIME_BIN") || "wasmtime")
  end

  defp workspace do
    root = MirrorNeuron.Config.string("MN_TEMP_DIR", :temp_dir)

    dir =
      Path.join(
        root,
        "mn-wasmtime-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    with :ok <- File.mkdir_p(root),
         :ok <- File.mkdir(dir) do
      case File.chmod(dir, 0o700) do
        :ok ->
          {:ok, dir}

        error ->
          File.rmdir(dir)
          error
      end
    end
  end
end
