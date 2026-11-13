defmodule MirrorNeuron.Runtime.LocalProcesses do
  @moduledoc "Stops only local run owners and their independently supervised workers."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.JobCalls

  @doc false
  def terminate_local_job(job_id) when is_binary(job_id) do
    with :ok <- terminate_local_job_runner(job_id),
         :ok <- terminate_local_agent_workers(job_id) do
      :ok
    end
  end

  defp terminate_local_job_child(job_id, pid) do
    case Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:local_job_stop_failed, job_id, reason}}
    end
  rescue
    exception ->
      {:error,
       {:local_job_stop_failed, job_id, {exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason -> {:error, {:local_job_stop_failed, job_id, {kind, reason}}}
  end

  defp terminate_local_job_runner(job_id) do
    case JobCalls.lookup_job_runner(job_id) do
      {:ok, pid} ->
        if node(pid) == Node.self(), do: terminate_local_job_child(job_id, pid), else: :ok

      :missing ->
        terminate_orphaned_local_coordinator(job_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminate_orphaned_local_coordinator(job_id) do
    case JobCalls.lookup_job(job_id) do
      {:ok, pid} ->
        if node(pid) == Node.self() do
          Process.exit(pid, :shutdown)
        end

        :ok

      _missing_or_remote ->
        :ok
    end
  end

  # Agent workers are supervised independently from their job runner. A durable
  # cancellation must stop them explicitly after the runner is removed, or they
  # can continue to emit fenced observations and retain service registrations.

  defp terminate_local_agent_workers(job_id) do
    with {:ok, observations} <- RedisStore.list_agents(job_id) do
      observations
      |> Enum.map(&(Map.get(&1, "agent_id") || Map.get(&1, "node_id")))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn agent_id, :ok ->
        case terminate_local_agent_worker(job_id, agent_id) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:local_agent_stop_failed, job_id, agent_id, reason}}}
        end
      end)
    end
  end

  defp terminate_local_agent_worker(job_id, agent_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _metadata} | _] ->
        if node(pid) == Node.self() do
          case DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.LocalAgentSupervisor, pid) do
            :ok -> :ok
            {:error, :not_found} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          :ok
        end

      _missing_or_remote ->
        :ok
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
