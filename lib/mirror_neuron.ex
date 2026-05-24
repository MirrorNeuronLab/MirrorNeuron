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

  def plan_manifest(input, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         :ok <- MirrorNeuron.BlueprintValidation.check_requirements(bundle.manifest) do
      MirrorNeuron.Scheduler.plan(bundle.manifest, opts)
    end
  end

  def run_manifest(input, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :run_manifest, [input, opts])
    else
      with :ok <- maybe_accept_new_job(opts),
           {:ok, bundle} <- JobBundle.load(input),
           :ok <- MirrorNeuron.BlueprintValidation.run_input_validation(bundle),
           :ok <- MirrorNeuron.BlueprintValidation.check_requirements(bundle.manifest),
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

  def reconcile_node(node_name, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :reconcile_node, [node_name, opts])
    else
      MirrorNeuron.Cluster.Reconciler.reconcile_node(node_name, opts)
    end
  end

  def drain_node(node_name, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :drain_node, [node_name, opts])
    else
      MirrorNeuron.Cluster.NodeDrainer.drain_node(node_name, opts)
    end
  end

  def cancel_node_drain(node_name, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :cancel_node_drain, [node_name, opts])
    else
      MirrorNeuron.Cluster.NodeDrainer.cancel_node_drain(node_name, opts)
    end
  end

  def set_node_maintenance(node_name, enabled, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :set_node_maintenance, [node_name, enabled, opts])
    else
      MirrorNeuron.Cluster.NodeDrainer.set_node_maintenance(node_name, enabled, opts)
    end
  end

  def node_drain_status(node_name) do
    if control_node?() do
      Control.call(__MODULE__, :node_drain_status, [node_name])
    else
      MirrorNeuron.Cluster.NodeDrainer.node_drain_status(node_name)
    end
  end

  def list_jobs(opts \\ []), do: Monitor.list_jobs(opts)
  def job_details(job_id, opts \\ []), do: Monitor.job_details(job_id, opts)
  def cluster_overview(opts \\ []), do: Monitor.cluster_overview(opts)
  def resource_list, do: MirrorNeuron.Resource.list()
  def resource_set(attrs), do: MirrorNeuron.Resource.set(attrs)
  def metrics, do: Monitor.metrics()
  def dead_letters(job_id), do: Monitor.dead_letters(job_id)
  def replay_dead_letter(job_id, index), do: Monitor.replay_dead_letter(job_id, index)
  def recover_unfinished_jobs(opts \\ []), do: Runtime.LocalRecovery.recover_unfinished_jobs(opts)
  def recover_job(job_id, opts \\ []), do: Runtime.LocalRecovery.recover_job(job_id, opts)

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
    result =
      if control_node?() do
        call_control_or_runtime(job_id, :cancel, [job_id])
      else
        case Runtime.cancel_job(job_id) do
          {:error, "job " <> _} ->
            call_runtime_by_job(job_id, Runtime, :cancel_job, [job_id])

          other ->
            other
        end
      end

    case result do
      {:error, "job " <> _ = reason} ->
        force_cancel_orphaned_job(job_id, reason)

      other ->
        other
    end
  end

  defp force_cancel_orphaned_job(job_id, original_error) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["pending", "running", "paused"] ->
        require Logger
        Logger.info("Job #{job_id} process not found, forcefully cancelling via Redis.")

        updates = %{
          "status" => "cancelled",
          "result" => %{"reason" => "forced cancellation of orphaned job"}
        }

        defaults = %{
          "graph_id" => job["graph_id"] || "unknown",
          "job_name" => job["job_name"] || "unknown",
          "root_agent_ids" => job["root_agent_ids"] || [],
          "placement_policy" => job["placement_policy"] || "local",
          "recovery_policy" => job["recovery_policy"] || "local_restart",
          "manifest_ref" => job["manifest_ref"] || %{},
          "submitted_at" => job["submitted_at"] || Runtime.timestamp()
        }

        RedisStore.persist_terminal_job(job_id, updates, defaults)

        MirrorNeuron.Runtime.EventBus.publish(job_id, %{
          type: :job_cancelled,
          reason: "forced cancellation",
          timestamp: Runtime.timestamp()
        })

        {:ok, "force cancelled"}

      {:ok, _job} ->
        {:error, "job is already in a terminal state"}

      {:error, reason} ->
        if is_binary(reason) and String.contains?(reason, "was not found") do
          {:error, reason}
        else
          {:error, original_error}
        end
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

  def pressure(job_id) do
    if control_node?() do
      call_control_or_runtime(job_id, :pressure, [job_id])
    else
      Runtime.pressure(job_id)
    end
  end

  defp control_node? do
    MirrorNeuron.Application.node_role() == "control"
  end

  defp maybe_accept_new_job(opts) do
    if Keyword.get(opts, :resource_admission, true) do
      MirrorNeuron.ResourceAdmission.check()
    else
      :ok
    end
  end

  defp call_control_or_runtime(job_id, function, args) do
    case Control.call(__MODULE__, function, args) do
      {:error, "no runtime nodes available in the connected cluster"} ->
        call_runtime_by_job(job_id, function, args)

      {:error, "job " <> _} ->
        call_runtime_by_job(job_id, function, args)

      other ->
        other
    end
  end

  defp call_runtime_by_job(job_id, function, args),
    do: call_runtime_by_job(job_id, __MODULE__, function, args)

  defp call_runtime_by_job(job_id, module, function, args) do
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

          case :rpc.call(node, module, function, args, 15_000) do
            {:badrpc, _reason} ->
              {:cont, {:error, "job #{job_id} is not running in the connected cluster"}}

            {:error, "job " <> _reason} ->
              {:cont, {:error, "job #{job_id} is not running in the connected cluster"}}

            reply ->
              {:halt, reply}
          end
        end
      )
    end
  end
end
