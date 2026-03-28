defmodule MirrorNeuron do
  alias MirrorNeuron.Cluster.Control
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Monitor
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  def validate_manifest(input) do
    with {:ok, bundle} <- JobBundle.load(input) do
      {:ok, bundle}
    end
  end

  def run_manifest(input, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :run_manifest, [input, opts])
    else
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

  def inspect_nodes do
    if control_node?() do
      Control.call(MirrorNeuron.Cluster.Manager, :nodes, [])
    else
      MirrorNeuron.Cluster.Manager.nodes()
    end
  end

  def list_jobs(opts \\ []), do: Monitor.list_jobs(opts)
  def job_details(job_id, opts \\ []), do: Monitor.job_details(job_id, opts)
  def cluster_overview(opts \\ []), do: Monitor.cluster_overview(opts)

  def pause(job_id) do
    if control_node?(),
      do: Control.call(__MODULE__, :pause, [job_id]),
      else: Runtime.pause_job(job_id)
  end

  def resume(job_id) do
    if control_node?(),
      do: Control.call(__MODULE__, :resume, [job_id]),
      else: Runtime.resume_job(job_id)
  end

  def cancel(job_id) do
    if control_node?(),
      do: Control.call(__MODULE__, :cancel, [job_id]),
      else: Runtime.cancel_job(job_id)
  end

  def send_message(job_id, agent_id, message) do
    if control_node?() do
      Control.call(__MODULE__, :send_message, [job_id, agent_id, message])
    else
      Runtime.send_message(job_id, agent_id, message)
    end
  end

  defp control_node? do
    MirrorNeuron.Application.node_role() == "control"
  end
end
