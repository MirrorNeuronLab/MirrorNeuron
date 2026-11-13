defmodule MirrorNeuron.Runtime.JobRunner.Processes do
  @moduledoc "Cleans previous attempts and stops only the owned coordinator and workers."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  def cleanup_previous_attempt(job_id, %{"restart_reason" => restart_reason})
      when restart_reason != "initial_start" do
    stop_stale_attempt_workers(job_id)

    case Runtime.cleanup_job_sandboxes(job_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("attempt sandbox cleanup was incomplete: #{inspect(reason)}")
    end

    case RedisStore.delete_service_instances(job_id: job_id) do
      :ok ->
        :ok

      {:ok, _instances} ->
        :ok

      {:error, reason} ->
        Logger.warning("attempt service cleanup was incomplete: #{inspect(reason)}")
    end

    RedisStore.clear_job_attempt_state(job_id)
  end

  def cleanup_previous_attempt(_job_id, _job), do: :ok

  defp stop_stale_attempt_workers(job_id) do
    case RedisStore.list_agents(job_id) do
      {:ok, observations} ->
        observations
        |> Enum.flat_map(fn observation ->
          case observation["agent_id"] || observation["node_id"] do
            agent_id when is_binary(agent_id) ->
              Horde.Registry.lookup(
                MirrorNeuron.DistributedRegistry,
                {:agent, job_id, agent_id}
              )
              |> Enum.map(&elem(&1, 0))

            _other ->
              []
          end
        end)
        |> Enum.uniq()
        |> stop_and_wait_for_workers()

      {:error, reason} ->
        Logger.warning("could not enumerate stale workers for #{job_id}: #{inspect(reason)}")
    end
  end

  defp stop_and_wait_for_workers(pids) do
    monitors =
      Enum.map(pids, fn pid ->
        monitor = Process.monitor(pid)
        Process.exit(pid, :shutdown)
        {pid, monitor}
      end)

    deadline = System.monotonic_time(:millisecond) + 5_000
    Enum.each(monitors, &wait_for_worker_stop(&1, deadline))
  end

  defp wait_for_worker_stop({pid, monitor}, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      timeout -> Process.demonitor(monitor, [:flush])
    end
  end

  def cancel_coordinator_start_timer(%{coordinator_start_timer_ref: ref})
      when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  def cancel_coordinator_start_timer(_state), do: :ok

  def stop_coordinator(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(monitor, [:flush])
        end
    end

    :ok
  end

  def stop_coordinator(_pid), do: :ok

  # Returning {:stop, :normal} directly from init is a failed child start to a
  # supervisor. During a transient restart Horde retries that start, even when
  # the durable job is already terminal or paused. Start successfully and stop
  # in a continuation so the normal exit is observed and is not restarted.
end
