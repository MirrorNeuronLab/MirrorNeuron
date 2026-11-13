defmodule MirrorNeuron.Runtime.JobCoordinator.Processes do
  @moduledoc "Worker discovery, readiness, control and owned process termination."

  require Logger

  alias MirrorNeuron.ServiceRegistry

  def wait_for_agents_ready(state, timeout_ms \\ 20_000) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agents_ready(state, started_at, timeout_ms)
  end

  # Keep this coordinator responsive while a service adapter shuts its project
  # down. Fast stops retain the synchronous receipt. A slower stop acknowledges
  # the persisted pause and emits job_paused only after physical confirmation.

  def wait_for_agents_stopped(state, timeout_ms) do
    wait_for_agents_stopped(state, timeout_ms, state.agent_ids)
  end

  def wait_for_agents_stopped(state, timeout_ms, agent_ids) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agents_stopped(state, started_at, timeout_ms, agent_ids)
  end

  defp do_wait_for_agents_stopped(state, started_at, timeout_ms, agent_ids) do
    running_agents = Enum.filter(agent_ids, &agent_ready?(state, &1))

    case running_agents do
      [] ->
        :ok

      _agents ->
        if System.monotonic_time(:millisecond) - started_at > timeout_ms do
          {:error, "timed out waiting for existing agents to stop before recovery"}
        else
          Process.sleep(25)
          do_wait_for_agents_stopped(state, started_at, timeout_ms, agent_ids)
        end
    end
  end

  def wait_for_agent_ready(state, agent_id, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms)
  end

  defp do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms) do
    if agent_ready?(state, agent_id) do
      :ok
    else
      if System.monotonic_time(:millisecond) - started_at > timeout_ms do
        {:error, "timed out waiting for recovered agent #{agent_id} to register"}
      else
        Process.sleep(25)
        do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms)
      end
    end
  end

  def agent_ready?(state, agent_id) do
    with {:ok, pid} <- lookup_registered_agent(state.job_id, agent_id) do
      pid_alive?(pid)
    else
      _ -> false
    end
  end

  defp pid_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  defp pid_alive?(pid) when is_pid(pid) do
    safe_remote_alive?(pid)
  end

  defp pid_alive?(_pid), do: false

  defp safe_remote_alive?(pid) do
    case :rpc.call(node(pid), Process, :alive?, [pid], 5_000) do
      true -> true
      _ -> false
    end
  rescue
    exception ->
      Logger.debug("remote pid liveness probe failed",
        pid: inspect(pid),
        error: Exception.message(exception)
      )

      false
  catch
    kind, reason ->
      Logger.debug("remote pid liveness probe failed",
        pid: inspect(pid),
        error: inspect({kind, reason})
      )

      false
  end

  def lookup_registered_agent(job_id, agent_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _meta} | _] when is_pid(pid) -> {:ok, pid}
      _ -> :missing
    end
  rescue
    exception ->
      Logger.debug("agent registry lookup failed",
        job_id: job_id,
        agent_id: agent_id,
        error: Exception.message(exception)
      )

      :missing
  catch
    kind, reason ->
      Logger.debug("agent registry lookup failed",
        job_id: job_id,
        agent_id: agent_id,
        error: inspect({kind, reason})
      )

      :missing
  end

  defp do_wait_for_agents_ready(state, started_at, timeout_ms) do
    missing_agents = Enum.reject(state.agent_ids, &agent_ready?(state, &1))

    case missing_agents do
      [] ->
        :ok

      missing ->
        if System.monotonic_time(:millisecond) - started_at > timeout_ms do
          {:error, "timed out waiting for agents to register: #{Enum.join(missing, ", ")}"}
        else
          Process.sleep(25)
          do_wait_for_agents_ready(state, started_at, timeout_ms)
        end
    end
  end

  def broadcast_agent_control(state, command) do
    Enum.each(state.agent_ids, fn agent_id ->
      case Horde.Registry.lookup(
             MirrorNeuron.DistributedRegistry,
             {:agent, state.job_id, agent_id}
           ) do
        [{pid, _}] -> GenServer.cast(pid, command)
        [] -> :ok
      end
    end)
  end

  def terminate_agent_workers(state) do
    terminate_agent_workers(state, state.agent_ids)
  end

  def terminate_agent_workers(state, agent_ids) do
    Enum.each(agent_ids, fn agent_id ->
      ServiceRegistry.deregister_agent(state.job_id, agent_id)

      case lookup_registered_agent(state.job_id, agent_id) do
        {:ok, pid} ->
          case safe_terminate_agent_child(pid) do
            :ok ->
              :ok

            {:error, :not_found} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "failed to terminate agent #{state.job_id}/#{agent_id}: #{inspect(reason)}"
              )

              safe_exit_agent(pid)
          end

        :missing ->
          :ok
      end
    end)
  end

  defp safe_terminate_agent_child(pid) do
    MirrorNeuron.Runtime.ErrorMonitor.expect_exit(pid)

    if node(pid) == Node.self() do
      DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.LocalAgentSupervisor, pid)
    else
      case :rpc.call(
             node(pid),
             DynamicSupervisor,
             :terminate_child,
             [MirrorNeuron.Runtime.LocalAgentSupervisor, pid],
             10_000
           ) do
        {:badrpc, reason} -> {:error, reason}
        other -> other
      end
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_exit_agent(pid) do
    if pid_alive?(pid) do
      Process.exit(pid, :kill)
    end

    :ok
  rescue
    exception ->
      Logger.debug("failed to force-exit agent process",
        pid: inspect(pid),
        error: Exception.message(exception)
      )

      :ok
  catch
    kind, reason ->
      Logger.debug("failed to force-exit agent process",
        pid: inspect(pid),
        error: inspect({kind, reason})
      )

      :ok
  end
end
