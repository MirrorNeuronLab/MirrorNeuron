defmodule MirrorNeuron do
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  def validate_manifest(input) do
    with {:ok, bundle} <- JobBundle.load(input) do
      {:ok, bundle}
    end
  end

  def run_manifest(input, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         {:ok, job_id, _pid} <-
           Runtime.start_job(bundle.manifest, Keyword.put(opts, :job_bundle, bundle)) do
      if Keyword.get(opts, :await, false) do
        case wait_for_job(job_id, Keyword.get(opts, :timeout, :infinity)) do
          {:ok, job} -> {:ok, job_id, job}
          other -> other
        end
      else
        {:ok, job_id}
      end
    end
  end

  def wait_for_job(job_id, timeout \\ :infinity) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["completed", "failed", "cancelled"] ->
        {:ok, job}

      _ ->
        Runtime.await_completion(job_id, timeout)
    end
  end

  def inspect_job(job_id), do: RedisStore.fetch_job(job_id)
  def inspect_agents(job_id), do: RedisStore.list_agents(job_id)
  def events(job_id), do: RedisStore.read_events(job_id)
  def inspect_nodes, do: MirrorNeuron.Cluster.Manager.nodes()

  def pause(job_id), do: Runtime.pause_job(job_id)
  def resume(job_id), do: Runtime.resume_job(job_id)
  def cancel(job_id), do: Runtime.cancel_job(job_id)
  def send_message(job_id, agent_id, message), do: Runtime.send_message(job_id, agent_id, message)
end
