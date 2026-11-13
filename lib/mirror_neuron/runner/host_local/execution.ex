defmodule MirrorNeuron.Runner.HostLocal.Execution do
  @moduledoc "Monitors command owners and starts isolated host ports."

  alias MirrorNeuron.Runner.HostLocal.Beacons
  alias MirrorNeuron.Runner.HostLocal.Command
  alias MirrorNeuron.Config
  alias MirrorNeuron.Runner.HostProcess
  alias MirrorNeuron.Runner.HostLocal.Ownership
  alias MirrorNeuron.Runner.HostLocal.Stream
  alias MirrorNeuron.Runner.WorkflowEnvironment

  def stream_command(command, env, workdir, config, opts) do
    run_command(command, env, workdir, config, opts, Keyword.get(opts, :message))
  end

  def run_command([command | args], env, workdir, config, opts, message) do
    owner = self()
    result_ref = make_ref()

    {runner, monitor_ref} =
      spawn_monitor(fn ->
        result =
          execute_command(
            owner,
            command,
            args,
            env,
            workdir,
            config,
            opts,
            message
          )

        send(owner, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^runner, _reason} ->
        {:error, "host local command process stopped before returning a result"}
    end
  end

  defp execute_command(owner, command, args, env, workdir, config, opts, message) do
    case Command.resolve_executable(command, workdir, env) do
      nil ->
        {:error,
         "host-local executable not found: #{command}. Verify the Core runtime image contains the interpreter or executable declared by the blueprint"}

      executable ->
        execute_resolved_command(
          owner,
          command,
          executable,
          args,
          env,
          workdir,
          config,
          opts,
          message
        )
    end
  end

  defp execute_resolved_command(
         owner,
         command,
         executable,
         args,
         env,
         workdir,
         config,
         opts,
         message
       ) do
    {port_executable, port_args, process_group?} = HostProcess.isolate(executable, args)
    max_output_bytes = max_output_bytes(config)
    timeout_ms = timeout_ms(config)
    deadline = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms

    beacon_state =
      Beacons.beacon_state(config, opts, message)
      |> Map.put(
        :budget,
        MirrorNeuron.Runner.CommandBudget.new(
          timeout_ms,
          Map.merge(Map.get(config, "environment", %{}), Map.new(env))
          |> Map.merge(WorkflowEnvironment.from_options(opts)),
          Beacons.now_ms()
        )
      )

    owner_ref = Process.monitor(owner)
    job_id = Keyword.get(opts, :job_id)

    :ok = Ownership.register_host_process(job_id, Keyword.get(opts, :agent_id))

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(port_executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, Enum.map(port_args, &String.to_charlist/1)},
          {:cd, String.to_charlist(workdir)},
          {:env,
           Enum.map(env, fn {key, value} ->
             {String.to_charlist(key),
              if(is_nil(value), do: false, else: String.to_charlist(value))}
           end)}
        ]
      )

    beacon_state = Beacons.emit_runtime_beacon(beacon_state, "started")

    Stream.collect_port_output(
      port,
      [],
      0,
      max_output_bytes,
      deadline,
      beacon_state,
      owner,
      owner_ref,
      process_group?,
      job_id
    )
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{command}: #{Exception.message(error)}"}
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
end
