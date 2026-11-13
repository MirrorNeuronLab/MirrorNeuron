defmodule MirrorNeuron.Runtime.StepInspector do
  @moduledoc false

  # Never call a busy AgentWorker's mailbox: runners execute inside that process.
  # Probe ownership independently, off the coordinator's event loop, with a bound
  # on the entire inspection (including registry and remote node lookups).
  def start(owner, job_id, step_id, token, agents) do
    work = fn ->
      task = Task.async(fn -> inspect_workers(job_id, agents) end)

      result =
        case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> %{}
        end

      send(owner, {:workflow_step_inspected, step_id, token, result})
    end

    case Process.whereis(MirrorNeuron.Runtime.RecoveryTaskSupervisor) do
      nil -> Task.start(work)
      _ -> Task.Supervisor.start_child(MirrorNeuron.Runtime.RecoveryTaskSupervisor, work)
    end
  end

  def inspect_workers(job_id, agents) do
    agents
    |> Task.async_stream(fn agent -> {agent, probe(job_id, agent)} end,
      max_concurrency: 16,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {agent, status}}, result -> Map.put(result, agent, status)
      _, result -> result
    end)
  end

  defp probe(job_id, agent) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent}) do
      [{pid, _} | _] when is_pid(pid) ->
        alive =
          if node(pid) == node(),
            do: Process.alive?(pid),
            else: :rpc.call(node(pid), Process, :alive?, [pid], 4_000)

        case alive do
          true -> "alive"
          false -> "dead"
          _ -> "unknown"
        end

      [] ->
        "dead"
    end
  rescue
    _ -> "unknown"
  catch
    _, _ -> "unknown"
  end
end
