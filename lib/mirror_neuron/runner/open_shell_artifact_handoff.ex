defmodule MirrorNeuron.Runner.OpenShellArtifactHandoff do
  @moduledoc "Core-owned durable OpenShell execution and artifact publication."
  alias MirrorNeuron.Runner.{OpenShell, OpenShellArtifactStore, Result}
  alias MirrorNeuron.Sandbox.OpenShellJobSandbox
  alias MirrorNeuron.Runner.OpenShellArtifactTransfer, as: Transfer
  alias MirrorNeuron.Persistence.RedisStore

  @version "mn.artifact_handoff/v1"

  def validate(config) do
    case config["artifact_handoff"] do
      nil ->
        :ok

      %{"version" => @version} ->
        cond do
          config["sync_shared_storage"] == true ->
            {:error, "artifact_handoff conflicts with legacy sync_shared_storage"}

          Enum.any?(
            [
              {"max_bytes", 1_000_000_000},
              {"max_files", 10_000},
              {"max_result_bytes", 4_000_000}
            ],
            fn {key, max_value} ->
              value = config["artifact_handoff"][key]
              not is_nil(value) and (not is_integer(value) or value < 1 or value > max_value)
            end
          ) ->
            {:error, "invalid artifact handoff quota"}

          config["reuse_shared_sandbox"] == false ->
            {:error, "artifact_handoff requires a job sandbox"}

          true ->
            :ok
        end

      _ ->
        {:error, "unsupported artifact_handoff version"}
    end
  end

  def run(payload, config, opts) do
    env = config["environment"] || %{}

    identity = %{
      "job_id" => Keyword.fetch!(opts, :job_id),
      "owner_node" => to_string(node()),
      "run_id" => Keyword.fetch!(opts, :run_id),
      "step_instance" => Keyword.fetch!(opts, :step_instance),
      "attempt" => Keyword.get(opts, :runtime_attempt) || Keyword.fetch!(opts, :attempt),
      "lease_epoch" => Keyword.fetch!(opts, :lease_epoch)
    }

    root = Path.expand(env["MN_JOB_SHARED_STORAGE_ROOT"] || "")

    shared =
      Path.expand(MirrorNeuron.Config.string("MN_SHARED_STORAGE_ROOT", :shared_storage_root))

    with true <- String.starts_with?(root, shared <> "/"),
         true <- valid_identity?(identity),
         :ok <- guard(identity, opts) do
      base = %{
        "root" => Path.join([root, "outputs", "runs", identity["run_id"], ".handoff"]),
        "identity" => identity,
        "trusted_root" => shared
      }

      hash =
        :crypto.hash(
          :sha256,
          Jason.encode!(%{"payload" => payload, "command" => config["command"]})
        )
        |> Base.encode16(case: :lower)

      with {:ok, state} <-
             OpenShellArtifactStore.call(base, "begin", %{
               "request_hash" => hash,
               "workspace" => "/sandbox/job/artifact-attempts",
               "sandbox" => %{}
             }) do
        resume(base, state, payload, config, opts)
      end
    else
      false ->
        {:error,
         %{"error" => "artifact handoff requires safe owner storage and runtime identity"}}

      {:error, _} = error ->
        error
    end
  rescue
    error ->
      {:error,
       %{
         "error" => Exception.message(error),
         "phase" => "artifact_handoff_failed",
         "retryable" => false
       }}
  end

  defp resume(base, %{"phase" => "committed"} = state, _payload, config, _opts) do
    cleanup(base, state, config)
    export_and_outcome(base, state, config)
  end

  defp resume(_base, %{"phase" => "unknown_blocked"} = state, _payload, _config, _opts),
    do: {:error, Map.put(state, "retryable", false)}

  defp resume(base, %{"phase" => "prepared"} = state, payload, config, opts) do
    with {:ok, sandbox} <- OpenShellJobSandbox.ensure(Keyword.fetch!(opts, :job_id), config),
         {:ok, state} <- OpenShellArtifactStore.call(base, "prepared", %{"sandbox" => sandbox}),
         {:ok, staged} <- OpenShell.stage_workspace(payload, config, opts) do
      try do
        with {:ok, inputs} <-
               prepare_inputs(base, %{
                 "payload" => payload,
                 "target" => Path.join(staged, ".inputs")
               }),
             :ok <- prepare(staged, state, inputs, config, opts),
             {:ok, :uploaded} <-
               OpenShell.upload_workspace(
                 cli(config),
                 sandbox["sandbox_name"],
                 staged,
                 state["workspace"]
               ),
             :ok <- guard(base["identity"], opts),
             {:ok, state} <- OpenShellArtifactStore.call(base, "started") do
          event(opts, "execution_started")
          # No automatic redispatch after this persisted boundary, even if SSH fails.
          dispatched =
            OpenShell.run_ssh_command(config, sandbox["sandbox_name"], sandbox["ssh_host"], [
              "python3",
              Path.join(state["workspace"], ".handoff/worker.py"),
              Path.join(state["workspace"], ".handoff/spec.json")
            ])

          state = capture_execution(base, state, dispatched)
          transfer(base, state, config, opts)
        end
      after
        File.rm_rf(staged)
      end
    end
  end

  defp resume(base, state, _payload, config, opts), do: transfer(base, state, config, opts)

  defp prepare_inputs(base, fields, remaining \\ 40) do
    case OpenShellArtifactStore.call(base, "inputs", fields) do
      {:error, %{"kind" => "FileNotFoundError"}} when remaining > 0 ->
        Process.sleep(250)
        prepare_inputs(base, fields, remaining - 1)

      result ->
        result
    end
  end

  defp capture_execution(base, state, {:ok, output, _code}) do
    case String.split(output, "__MN_ARTIFACT_EXECUTION__", parts: 2) do
      [_, encoded] ->
        case Jason.decode(String.trim(encoded)) do
          {:ok, %{"exit_code" => code} = result} when is_integer(code) ->
            case OpenShellArtifactStore.call(base, "execution", %{
                   "execution" => Result.sanitize(result)
                 }) do
              {:ok, updated} -> updated
              _ -> state
            end

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp capture_execution(_base, state, _dispatched), do: state

  defp prepare(staged, state, inputs, config, opts) do
    remote = state["workspace"]
    dir = Path.join(staged, ".handoff")
    File.mkdir_p!(dir)

    for name <- ["files.py", "worker.py", "cache.py"],
        do: File.cp!(Path.join(OpenShellArtifactStore.helper_dir(), name), Path.join(dir, name))

    environment =
      (config["environment"] || %{})
      |> Map.merge(MirrorNeuron.Runner.WorkflowEnvironment.from_options(opts))
      |> Map.merge(%{
        "MN_INPUT_FILE" => Path.join(remote, "mirror_neuron_input.json"),
        "MN_MESSAGE_FILE" => Path.join(remote, "mirror_neuron_message.json"),
        "MN_CONTEXT_FILE" => Path.join(remote, "mirror_neuron_context.json"),
        "MN_WORKDIR" => OpenShell.resolve_workdir(config, remote),
        "MN_RUN_ID" => state["producer"]["run_id"],
        "MN_WORKFLOW_RUN_ID" => state["producer"]["run_id"],
        "MN_JOB_ID" => state["producer"]["job_id"],
        "MN_AGENT_ID" => Keyword.fetch!(opts, :agent_id),
        "MN_ARTIFACT_OUTPUT_DIR" => Path.join(remote, "outputs"),
        "MN_ARTIFACT_INPUT_INDEX" => Path.join(remote, ".inputs/index.json"),
        "MN_ARTIFACT_COMMIT_ID" => state["commit_id"],
        "MN_ARTIFACT_PRODUCER" => Jason.encode!(state["producer"]),
        "MN_STEP_RESULT_FILE" => Path.join(remote, "result.json"),
        "MN_JOB_SHARED_STORAGE_ROOT" => Path.join(remote, "local"),
        "MN_RUNS_ROOT" => Path.join(remote, "local/runs"),
        "MN_JOB_OUTPUT_DIR" => Path.join(remote, "outputs"),
        "MN_JOB_INPUT_DIR" => Path.join(remote, ".inputs")
      })

    limits = config["artifact_handoff"]

    spec = %{
      "workspace" => remote,
      "cache_root" => cache_root(state),
      "workdir" => OpenShell.resolve_workdir(config, remote),
      "command" => config["command"],
      "environment" => environment,
      "producer" => state["producer"],
      "commit_id" => state["commit_id"],
      "inputs" => inputs,
      "max_bytes" => Map.get(limits, "max_bytes", 64_000_000),
      "max_files" => Map.get(limits, "max_files", 256),
      "max_result_bytes" => Map.get(limits, "max_result_bytes", 1_000_000),
      "timeout_seconds" => Map.get(config, "timeout_seconds", 600)
    }

    File.write!(Path.join(dir, "spec.json"), Jason.encode!(spec))
    reuse_cached_inputs(staged, state, inputs, config)
    :ok
  end

  defp cache_root(state),
    do:
      "/sandbox/job/.artifact-cache/" <>
        Base.encode16(:crypto.hash(:sha256, state["producer"]["job_id"]), case: :lower)

  defp reuse_cached_inputs(staged, state, inputs, config) do
    script =
      "import hashlib,json,pathlib,sys; root=pathlib.Path(sys.argv[1]); refs=json.loads(sys.argv[2]); print(json.dumps([r['sha256'] for r in refs if (root/r['sha256']).is_file() and not (root/r['sha256']).is_symlink() and (root/r['sha256']).stat().st_size==r['size_bytes'] and hashlib.sha256((root/r['sha256']).read_bytes()).hexdigest()==r['sha256']]))"

    sandbox = state["sandbox"]

    case OpenShell.run_ssh_command(config, sandbox["sandbox_name"], sandbox["ssh_host"], [
           "python3",
           "-c",
           script,
           cache_root(state),
           Jason.encode!(inputs)
         ]) do
      {:ok, output, 0} ->
        case Jason.decode(String.trim(output)) do
          {:ok, hashes} when is_list(hashes) ->
            for ref <- inputs,
                ref["sha256"] in hashes,
                do: File.rm(Path.join(staged, ".inputs/files/" <> ref["sha256"]))

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp transfer(base, state, config, opts) do
    stage = Path.join(base["root"], "staging/" <> state["commit_id"])
    File.mkdir_p!(stage)
    event(opts, "outputs_transferring")

    with {:ok, execution} <- recover_execution(state, stage, config),
         {:ok, updated} <-
           OpenShellArtifactStore.call(base, "execution", %{"execution" => execution}) do
      case commit(base, updated, stage, config, opts) do
        {:ok, _} = ok ->
          ok

        {:error, %{"artifact_receipt" => _}} = outcome ->
          outcome

        {:error, reason} ->
          {:error,
           %{
             "error" => "artifact handoff incomplete",
             "phase" =>
               if(is_map(reason),
                 do: reason["phase"] || "outputs_transferring",
                 else: "outputs_transferring"
               ),
             "execution" => execution,
             "transfer_error" => reason,
             "retryable" => false
           }}
      end
    else
      {:error, reason} ->
        OpenShellArtifactStore.call(base, "unknown")

        {:error,
         %{
           "phase" => "unknown_blocked",
           "error" => "execution outcome unknown; explicit retry required",
           "transfer_error" => reason,
           "execution" => state["execution"],
           "retryable" => false
         }}
    end
  end

  defp recover_execution(%{"execution" => execution}, _stage, _config) when is_map(execution),
    do: {:ok, execution}

  defp recover_execution(state, stage, config) do
    with :ok <- Transfer.download(config, state, "sealed/execution.json", stage),
         {:ok, raw} <- File.read(Path.join(stage, "execution.json")),
         {:ok, execution} <- Jason.decode(raw) do
      {:ok, Result.sanitize(execution)}
    end
  end

  defp commit(base, state, stage, config, opts) do
    execution = state["execution"]
    limits = config["artifact_handoff"]

    if execution["seal_error"] do
      {:error,
       %{
         "phase" => "artifact_verification_failed",
         "execution" => execution,
         "error" => execution["seal_error"]
       }}
    else
      with :ok <- Transfer.download(config, state, "sealed/manifest.json", stage),
           {:ok, raw} <- File.read(Path.join(stage, "manifest.json")),
           {:ok, manifest} <- Jason.decode(raw),
           :ok <- Transfer.files(config, state, stage, manifest),
           :ok <- guard(base["identity"], opts),
           {:ok, committed} <-
             OpenShellArtifactStore.call(base, "commit", %{
               "stage" => stage,
               "execution" => execution,
               "max_files" => Map.get(limits, "max_files", 256),
               "max_bytes" => Map.get(limits, "max_bytes", 64_000_000)
             }) do
        event(opts, "committed")

        case cleanup(base, committed, config) do
          {:ok, cleaned} ->
            export_and_outcome(base, cleaned, config)

          _ ->
            export_and_outcome(
              base,
              Map.put(committed, "cleanup_warning", "cleanup status pending"),
              config
            )
        end
      end
    end
  end

  @doc false
  def cleanup(base, state, config) do
    sandbox = state["sandbox"]

    warning =
      case OpenShell.run_ssh_command(config, sandbox["sandbox_name"], sandbox["ssh_host"], [
             "rm",
             "-rf",
             "--",
             state["workspace"]
           ]) do
        {:ok, _, 0} -> nil
        _ -> "committed artifacts retained; sandbox cleanup pending"
      end

    OpenShellArtifactStore.call(base, "cleanup", %{"warning" => warning})
  end

  defp export_and_outcome(base, state, config) do
    if config["artifact_handoff"]["export_outputs"] == true and
         state["receipt"]["execution"]["exit_code"] == 0 do
      with {:ok, _} <-
             OpenShellArtifactStore.call(base, "export", %{
               "target" => config["environment"]["MN_JOB_OUTPUT_DIR"]
             }) do
        outcome(base, state)
      end
    else
      outcome(base, state)
    end
  end

  defp outcome(_base, state) do
    execution = state["receipt"]["execution"]

    result =
      Map.merge(execution, %{
        "phase" => "committed",
        "artifact_receipt" => Map.drop(state["receipt"], ["execution"]),
        "retryable" => false,
        "cleanup_warning" => state["cleanup_warning"]
      })

    if execution["exit_code"] == 0,
      do: {:ok, result},
      else: {:error, Map.put(result, "phase", "execution_failed")}
  end

  defp guard(identity, opts) do
    if Keyword.get(opts, :coordinator_node, node()) != node() do
      {:error, "artifact handoff must execute on the owner node"}
    else
      validator = Keyword.get(opts, :lease_validator, &RedisStore.validate_job_attempt_epoch/2)
      validator.(identity["job_id"], identity["lease_epoch"])
    end
  end

  defp event(opts, phase) do
    case Keyword.get(opts, :event_callback) do
      fun when is_function(fun, 2) -> fun.(:artifact_handoff, %{"phase" => phase})
      _ -> :ok
    end
  end

  defp valid_identity?(id) do
    is_integer(id["lease_epoch"]) and id["lease_epoch"] >= 0 and
      is_binary(id["step_instance"]) and byte_size(id["step_instance"]) in 1..512 and
      is_binary(id["run_id"]) and safe_relative?(id["run_id"]) and
      not String.contains?(id["run_id"], "/")
  end

  defp safe_relative?(path),
    do:
      is_binary(path) and path != "" and Path.type(path) == :relative and
        not String.contains?(path, ["\\", "\0"]) and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

  defp cli(config),
    do:
      Map.get(
        config,
        "sandbox_cli",
        MirrorNeuron.Config.executable("MN_OPENSHELL_BIN", :openshell_bin)
      )
end
