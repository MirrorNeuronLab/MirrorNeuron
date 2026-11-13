defmodule MirrorNeuron.Runner.HostLocal.Ownership do
  @moduledoc "Tracks and terminates only command processes owned by the requested job and agents."

  @host_process_registry MirrorNeuron.Runner.HostProcessRegistry
  @cancellation_timeout_ms 2_000

  def terminate_job(job_id) when is_binary(job_id) do
    terminate_agents(job_id, :all)
  end

  def terminate_agents(job_id, agent_ids) do
    if Process.whereis(@host_process_registry) do
      runners =
        @host_process_registry
        |> Registry.lookup(job_id)
        |> Enum.filter(fn {_pid, agent_id} -> agent_ids == :all or agent_id in agent_ids end)
        |> Enum.map(fn {pid, _metadata} -> {pid, Process.monitor(pid)} end)

      Enum.each(runners, fn {pid, _monitor_ref} ->
        send(pid, {:terminate_host_job, job_id})
      end)

      await_terminated_runners(runners, cancellation_deadline())
    else
      :ok
    end
  end

  defp cancellation_deadline do
    System.monotonic_time(:millisecond) + @cancellation_timeout_ms
  end

  def register_host_process(job_id, agent_id) when is_binary(job_id) and job_id != "" do
    if Process.whereis(@host_process_registry) do
      {:ok, _value} = Registry.register(@host_process_registry, job_id, agent_id)
    end

    :ok
  end

  def register_host_process(_job_id, _agent_id), do: :ok

  defp await_terminated_runners([], _deadline), do: :ok

  defp await_terminated_runners([{pid, monitor_ref} | rest], deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        await_terminated_runners(rest, deadline)
    after
      timeout ->
        Enum.each([{pid, monitor_ref} | rest], fn {_runner, ref} ->
          Process.demonitor(ref, [:flush])
        end)

        {:error, {:host_local_cleanup_timeout, pid}}
    end
  end
end
