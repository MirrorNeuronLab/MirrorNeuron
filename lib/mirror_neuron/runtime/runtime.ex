defmodule MirrorNeuron.Runtime do
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{EventBus, JobRunner}

  def start_job(manifest, opts \\ []) do
    job_id = Keyword.get(opts, :job_id, generate_job_id(manifest.graph_id))

    spec = {JobRunner, {job_id, manifest, opts}}

    with {:ok, pid} <-
           Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
      {:ok, job_id, pid}
    end
  end

  def pause_job(job_id), do: call_job(job_id, :pause)
  def resume_job(job_id), do: call_job(job_id, :resume)
  def cancel_job(job_id), do: call_job(job_id, :cancel)

  def send_message(job_id, agent_id, message) when is_map(message) do
    call_job(job_id, {:send_message, agent_id, message})
  end

  def await_completion(job_id, timeout) do
    wait_until_terminal(job_id, timeout, System.monotonic_time(:millisecond))
  end

  def deliver(job_id, agent_id, message) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:deliver, message})
        :ok

      [] ->
        EventBus.publish(job_id, %{
          type: :dead_letter,
          agent_id: agent_id,
          message: message,
          timestamp: timestamp()
        })

        {:error, "agent #{agent_id} is not running for job #{job_id}"}
    end
  end

  defp call_job(job_id, message) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
      [{pid, _}] -> GenServer.call(pid, message, 15_000)
      [] -> {:error, "job #{job_id} is not running in the connected cluster"}
    end
  end

  defp wait_until_terminal(job_id, timeout, started_at) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["completed", "failed", "cancelled"] ->
        {:ok, job}

      {:ok, _job} ->
        if timeout != :infinity and System.monotonic_time(:millisecond) - started_at > timeout do
          {:error, "timed out waiting for job #{job_id}"}
        else
          Process.sleep(100)
          wait_until_terminal(job_id, timeout, started_at)
        end

      {:error, _reason} ->
        if timeout != :infinity and System.monotonic_time(:millisecond) - started_at > timeout do
          {:error, "timed out waiting for job #{job_id}"}
        else
          Process.sleep(100)
          wait_until_terminal(job_id, timeout, started_at)
        end
    end
  end

  defp generate_job_id(graph_id) do
    suffix =
      6
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "#{graph_id}-#{System.system_time(:millisecond)}-#{suffix}"
  end

  def timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
