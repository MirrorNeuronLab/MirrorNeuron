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

  def add_node(node_name) do
    if control_node?() do
      Control.call(MirrorNeuron.Cluster.Manager, :add_node, [node_name])
    else
      MirrorNeuron.Cluster.Manager.add_node(node_name)
    end
  end

  def remove_node(node_name) do
    if control_node?() do
      Control.call(MirrorNeuron.Cluster.Manager, :remove_node, [node_name])
    else
      MirrorNeuron.Cluster.Manager.remove_node(node_name)
    end
  end

  def list_jobs(opts \\ []), do: Monitor.list_jobs(opts)
  def job_details(job_id, opts \\ []), do: Monitor.job_details(job_id, opts)
  def cluster_overview(opts \\ []), do: Monitor.cluster_overview(opts)

  def pause(job_id) do
    if control_node?() do
      call_control_or_runtime(job_id, :pause, [job_id])
    else
      Runtime.pause_job(job_id)
    end
  end

  def resume(job_id) do
    if control_node?() do
      call_control_or_runtime(job_id, :resume, [job_id])
    else
      Runtime.resume_job(job_id)
    end
  end

  def cancel(job_id) do
    if control_node?() do
      call_control_or_runtime(job_id, :cancel, [job_id])
    else
      Runtime.cancel_job(job_id)
    end
  end

  def cleanup_jobs(opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :cleanup_jobs, [opts])
    else
      Runtime.cleanup_jobs(opts)
    end
  end

  def send_message(job_id, agent_id, message) do
    if control_node?() do
      call_control_or_runtime(job_id, :send_message, [job_id, agent_id, message])
    else
      Runtime.send_message(job_id, agent_id, message)
    end
  end

  defp control_node? do
    MirrorNeuron.Application.node_role() == "control"
  end

  defp call_control_or_runtime(job_id, function, args) do
    case Control.call(__MODULE__, function, args) do
      {:error, "no runtime nodes available in the connected cluster"} ->
        call_runtime_by_job(job_id, function, args)

      other ->
        other
    end
  end

  defp call_runtime_by_job(job_id, function, args) do
    with {:ok, agents} <- RedisStore.list_agents(job_id) do
      agents
      |> Enum.map(& &1["assigned_node"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce_while(
        {:error, "job #{job_id} is not running in the connected cluster"},
        fn node_name, _acc ->
          node = String.to_atom(node_name)
          _ = Node.connect(node)

          case :rpc.call(node, __MODULE__, function, args, 15_000) do
            {:badrpc, _reason} ->
              {:cont, {:error, "job #{job_id} is not running in the connected cluster"}}

            reply ->
              {:halt, reply}
          end
        end
      )
    end
  end
end
