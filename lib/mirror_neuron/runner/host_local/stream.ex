defmodule MirrorNeuron.Runner.HostLocal.Stream do
  @moduledoc "Collects bounded command output and enforces cancellation, progress and liveness deadlines."

  alias MirrorNeuron.Runner.HostLocal.Beacons
  alias MirrorNeuron.Runner.HostLocal.EventDecoder
  alias MirrorNeuron.Runner.HostProcess
  alias MirrorNeuron.Runner.HostLocal.Output

  def collect_port_output(
        port,
        chunks,
        bytes,
        max_output_bytes,
        _previous_deadline,
        beacon_state,
        owner,
        owner_ref,
        process_group?,
        job_id
      ) do
    {remaining, budget} =
      MirrorNeuron.Runner.CommandBudget.remaining(beacon_state.budget, Beacons.now_ms())

    beacon_state = %{beacon_state | budget: budget}
    deadline = if remaining == :infinity, do: nil, else: Beacons.now_ms() + remaining
    timeout = receive_timeout(deadline, beacon_state)

    receive do
      {^port, {:data, data}} ->
        now = Beacons.now_ms()
        {clean_data, next_beacon_state} = EventDecoder.filter_beacon_output(data, beacon_state)
        next_beacon_state = Beacons.maybe_emit_runtime_beacon(next_beacon_state, now)

        {next_chunks, next_bytes} =
          Output.append_output(chunks, bytes, clean_data, max_output_bytes)

        collect_port_output(
          port,
          next_chunks,
          next_bytes,
          max_output_bytes,
          deadline,
          next_beacon_state,
          owner,
          owner_ref,
          process_group?,
          job_id
        )

      {^port, {:exit_status, exit_code}} ->
        {tail, next_beacon_state} = EventDecoder.flush_beacon_buffer(beacon_state)
        {next_chunks, _next_bytes} = Output.append_output(chunks, bytes, tail, max_output_bytes)
        _ = Beacons.emit_runtime_beacon(next_beacon_state, "completed")
        {:ok, next_chunks |> Enum.reverse() |> IO.iodata_to_binary(), exit_code}

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        HostProcess.terminate(port, process_group?)
        {:error, "host local command owner terminated"}

      {:terminate_host_job, ^job_id} when is_binary(job_id) ->
        HostProcess.terminate(port, process_group?)
        {:error, "host local command cancelled"}
    after
      timeout ->
        now = Beacons.now_ms()

        {remaining, budget} =
          MirrorNeuron.Runner.CommandBudget.remaining(beacon_state.budget, now)

        beacon_state = %{beacon_state | budget: budget}

        cond do
          remaining == 0 ->
            HostProcess.terminate(port, process_group?)

            {:error,
             %{
               "error" => "host local command timed out",
               "timeout_ms" => max(timeout, 0),
               "stdout" => chunks |> Enum.reverse() |> IO.iodata_to_binary()
             }}

          Beacons.beacon_missed?(beacon_state, now) ->
            HostProcess.terminate(port, process_group?)
            missed_payload = Beacons.beacon_payload(beacon_state, "missed", "agent", now)
            Beacons.emit_beacon_event(beacon_state, :agent_beacon_missed, missed_payload)

            {:error,
             %{
               "error" => "agent beacon deadline exceeded",
               "timeout_ms" => beacon_state.timeout_ms,
               "stdout" => chunks |> Enum.reverse() |> IO.iodata_to_binary(),
               "beacon" => missed_payload
             }}

          true ->
            next_beacon_state = Beacons.maybe_emit_runtime_beacon(beacon_state, now)

            collect_port_output(
              port,
              chunks,
              bytes,
              max_output_bytes,
              deadline,
              next_beacon_state,
              owner,
              owner_ref,
              process_group?,
              job_id
            )
        end
    end
  end

  defp receive_timeout(deadline, beacon_state) do
    now = Beacons.now_ms()

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
end
