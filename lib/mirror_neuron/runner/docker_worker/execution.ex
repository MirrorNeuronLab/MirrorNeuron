defmodule MirrorNeuron.Runner.DockerWorker.Execution do
  @moduledoc "Collects command output under owner monitoring and deadline enforcement."

  require Logger

  alias MirrorNeuron.Runner.DockerCommand
  alias MirrorNeuron.Runner.DockerWorker.Observations
  alias MirrorNeuron.Runner.DockerWorker.Output
  alias MirrorNeuron.Runner.DockerWorker.Settings

  def run_docker(args, container_name, config, opts) do
    docker_bin = Settings.docker_bin(config)
    executable = System.find_executable(docker_bin) || docker_bin
    timeout_ms = Settings.timeout_ms(config)
    deadline = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms

    event_state =
      Observations.agent_event_state(config, opts)
      |> Map.put(
        :budget,
        MirrorNeuron.Runner.CommandBudget.new(
          timeout_ms,
          Map.merge(
            Map.get(config, "environment", %{}),
            MirrorNeuron.Runner.WorkflowEnvironment.from_options(opts)
          ),
          System.monotonic_time(:millisecond)
        )
      )

    Observations.emit_runner_event(opts, "docker_worker_command_started", %{
      "category" => "system",
      "message" => "DockerWorker command started",
      "status" => "started",
      "runner" => "docker_worker",
      "target" => container_name
    })

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, Enum.map(args, &String.to_charlist/1)}
        ]
      )

    collect_docker_output(
      port,
      container_name,
      config,
      opts,
      [],
      0,
      Settings.max_output_bytes(config),
      deadline,
      event_state
    )
  rescue
    error in ErlangError ->
      {:error, "failed to invoke docker worker: #{Exception.message(error)}"}
  end

  defp collect_docker_output(
         port,
         container_name,
         config,
         opts,
         chunks,
         bytes,
         max_output_bytes,
         _previous_deadline,
         event_state
       ) do
    owner_ref = Keyword.fetch!(opts, :docker_owner_monitor)

    {remaining, budget} =
      MirrorNeuron.Runner.CommandBudget.remaining(
        event_state.budget,
        System.monotonic_time(:millisecond)
      )

    event_state = %{event_state | budget: budget}

    deadline =
      if remaining == :infinity, do: nil, else: System.monotonic_time(:millisecond) + remaining

    receive do
      {^port, {:data, data}} ->
        {clean_data, next_event_state} = Observations.filter_agent_event_output(data, event_state)

        {next_chunks, next_bytes} =
          Output.append_output(chunks, bytes, clean_data, max_output_bytes)

        collect_docker_output(
          port,
          container_name,
          config,
          opts,
          next_chunks,
          next_bytes,
          max_output_bytes,
          deadline,
          next_event_state
        )

      {^port, {:exit_status, exit_code}} ->
        {tail, next_event_state} = Observations.flush_agent_event_buffer(event_state)
        {next_chunks, _next_bytes} = Output.append_output(chunks, bytes, tail, max_output_bytes)
        output = next_chunks |> Enum.reverse() |> IO.iodata_to_binary()

        Observations.emit_runner_event(opts, "docker_worker_command_completed", %{
          "category" => if(exit_code == 0, do: "system", else: "error"),
          "message" =>
            if(exit_code == 0,
              do: "DockerWorker command completed",
              else: "DockerWorker command failed"
            ),
          "status" => if(exit_code == 0, do: "completed", else: "failed"),
          "runner" => "docker_worker",
          "target" => container_name,
          "result_summary" => Output.compact_output_tail(output),
          "details" => %{
            "exit_code" => exit_code,
            "agent_event_prefix" => next_event_state.prefix
          }
        })

        {:ok, output, exit_code}

      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        stop_owned_command(port, container_name, config, opts)

      :terminate_docker_command ->
        stop_owned_command(port, container_name, config, opts)
    after
      receive_timeout(deadline) ->
        {remaining, budget} =
          MirrorNeuron.Runner.CommandBudget.remaining(
            event_state.budget,
            System.monotonic_time(:millisecond)
          )

        if remaining != 0 do
          collect_docker_output(
            port,
            container_name,
            config,
            opts,
            chunks,
            bytes,
            max_output_bytes,
            deadline,
            %{event_state | budget: budget}
          )
        else
          cleanup_result = stop_owned_command(port, container_name, config, opts)
          output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

          Observations.emit_runner_event(opts, "docker_worker_command_timed_out", %{
            "category" => "error",
            "message" => "DockerWorker command timed out",
            "status" => "failed",
            "runner" => "docker_worker",
            "target" => container_name,
            "duration_ms" => timeout_ms_from_deadline(deadline),
            "result_summary" => Output.compact_output_tail(output)
          })

          {:error,
           %{
             "error" => "docker worker command timed out",
             "timeout_ms" => timeout_ms_from_deadline(deadline),
             "cleanup_result" => inspect(cleanup_result),
             "stdout" => output
           }}
        end
    end
  end

  defp receive_timeout(nil), do: :infinity

  defp receive_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp timeout_ms_from_deadline(nil), do: nil

  defp timeout_ms_from_deadline(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp stop_owned_command(port, container_name, config, opts) do
    # Disconnect output while cleanup retries so an unreachable Docker daemon
    # cannot leave an abandoned command filling this process's mailbox.
    if Port.info(port), do: Port.close(port)

    result =
      DockerCommand.stop(
        Settings.docker_bin(config),
        container_name,
        Keyword.fetch!(opts, :docker_invocation_dir)
      )

    case result do
      :ok ->
        {:error, %{"error" => "docker worker command interrupted"}}

      {:error, reason} ->
        # Keep ownership registered until cleanup succeeds. Pause/resume and
        # cancellation must not mistake a failed Docker RPC for reclaimed work.
        Logger.warning("DockerWorker command cleanup failed; retrying: #{inspect(reason)}")

        Process.sleep(1_000)
        stop_owned_command(port, container_name, config, opts)
    end
  end
end
