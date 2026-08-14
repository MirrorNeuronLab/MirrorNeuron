defmodule MirrorNeuron do
  alias MirrorNeuron.Cluster.Control
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Monitor
  alias MirrorNeuron.Operations
  alias MirrorNeuron.Persistence.{CancellationStore, RedisStore}
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.CancellationReconciler

  @cluster_job_control_timeout_ms 8_000

  def validate_manifest(input) do
    with {:ok, bundle} <- JobBundle.load(input) do
      {:ok, bundle}
    end
  end

  def plan_manifest(input, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         :ok <- MirrorNeuron.ServicePreflight.run(bundle),
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
           :ok <- MirrorNeuron.ServicePreflight.run(bundle),
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

  @doc "Creates a durable job definition without starting an execution."
  def create_job(input, opts \\ []), do: MirrorNeuron.Runtime.StableJob.create(input, opts)

  def get_job(job_id), do: MirrorNeuron.Runtime.StableJob.get(job_id)
  def list_stable_jobs(opts \\ []), do: MirrorNeuron.Runtime.StableJob.list(opts)
  def list_stable_jobs_page(opts \\ []), do: MirrorNeuron.Runtime.StableJob.list_page(opts)
  def update_job(job_id, attrs, opts \\ []), do: MirrorNeuron.Runtime.StableJob.update(job_id, attrs, opts)

  def update_job_bundle(job_id, input, attrs \\ %{}, opts \\ []),
    do: MirrorNeuron.Runtime.StableJob.replace_bundle(job_id, input, attrs, opts)

  def archive_job(job_id, opts \\ []), do: MirrorNeuron.Runtime.StableJob.archive(job_id, opts)
  def reset_job_data(job_id), do: MirrorNeuron.Runtime.StableJob.reset_data(job_id)

  def delete_stable_job(job_id, opts \\ []),
    do: MirrorNeuron.Runtime.StableJob.delete(job_id, opts)

  def start_run(job_id, opts \\ []), do: MirrorNeuron.Runtime.StableJob.start_run(job_id, opts)
  def list_runs(job_id), do: MirrorNeuron.Runtime.StableJob.list_runs(job_id)
  def list_runs_page(job_id, opts \\ []), do: MirrorNeuron.Runtime.StableJob.list_runs_page(job_id, opts)
  def delete_run(run_id, opts \\ []), do: MirrorNeuron.Runtime.StableJob.delete_run(run_id, opts)

  def deploy_manifest(input, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :deploy_manifest, [input, opts])
    else
      MirrorNeuron.Runtime.DeploymentController.deploy_manifest(input, opts)
    end
  end

  def update_deployment(deployment_key, input, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :update_deployment, [deployment_key, input, opts])
    else
      MirrorNeuron.Runtime.DeploymentController.update_deployment(deployment_key, input, opts)
    end
  end

  def promote_deployment(id_or_key, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :promote_deployment, [id_or_key, opts])
    else
      MirrorNeuron.Runtime.DeploymentController.promote_deployment(id_or_key, opts)
    end
  end

  def rollback_deployment(id_or_key, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :rollback_deployment, [id_or_key, opts])
    else
      MirrorNeuron.Runtime.DeploymentController.rollback_deployment(id_or_key, opts)
    end
  end

  def get_deployment(id_or_key) do
    if control_node?() do
      Control.call(__MODULE__, :get_deployment, [id_or_key])
    else
      MirrorNeuron.Runtime.DeploymentController.get_deployment(id_or_key)
    end
  end

  def list_deployments(opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :list_deployments, [opts])
    else
      MirrorNeuron.Runtime.DeploymentController.list_deployments(opts)
    end
  end

  def pause_deployment(id_or_key, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :pause_deployment, [id_or_key, opts])
    else
      MirrorNeuron.Runtime.DeploymentController.pause_deployment(id_or_key, opts)
    end
  end

  def resume_deployment(id_or_key, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :resume_deployment, [id_or_key, opts])
    else
      MirrorNeuron.Runtime.DeploymentController.resume_deployment(id_or_key, opts)
    end
  end

  def fail_deployment(id_or_key, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :fail_deployment, [id_or_key, opts])
    else
      MirrorNeuron.Runtime.DeploymentController.fail_deployment(id_or_key, opts)
    end
  end

  def create_schedule(input, schedule \\ %{}, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :create_schedule, [input, schedule, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.create_schedule(input, schedule, opts)
    end
  end

  def create_job_schedule(job_id, schedule \\ %{}, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :create_job_schedule, [job_id, schedule, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.create_job_schedule(job_id, schedule, opts)
    end
  end

  def update_schedule(schedule_id, attrs, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :update_schedule, [schedule_id, attrs, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.update_schedule(schedule_id, attrs, opts)
    end
  end

  def pause_schedule(schedule_id, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :pause_schedule, [schedule_id, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.pause_schedule(schedule_id, opts)
    end
  end

  def resume_schedule(schedule_id, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :resume_schedule, [schedule_id, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.resume_schedule(schedule_id, opts)
    end
  end

  def delete_schedule(schedule_id, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :delete_schedule, [schedule_id, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.delete_schedule(schedule_id, opts)
    end
  end

  def get_schedule(schedule_id) do
    if control_node?() do
      Control.call(__MODULE__, :get_schedule, [schedule_id])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.get_schedule(schedule_id)
    end
  end

  def list_schedules(opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :list_schedules, [opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.list_schedules(opts)
    end
  end

  def dispatch_schedule(schedule_id, payload \\ %{}, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :dispatch_schedule, [schedule_id, payload, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.dispatch_schedule(schedule_id, payload, opts)
    end
  end

  def emit_trigger_event(event_type, payload \\ %{}, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :emit_trigger_event, [event_type, payload, opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.emit_event(event_type, payload, opts)
    end
  end

  def list_trigger_events(opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :list_trigger_events, [opts])
    else
      MirrorNeuron.Runtime.ScheduleDispatcher.list_events(opts)
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
  def export_job_backup(job_id), do: MirrorNeuron.JobBackup.export_job(job_id)

  def restore_job_backup(backup, bundle_files, opts \\ []),
    do: MirrorNeuron.JobBackup.restore_job(backup, bundle_files, opts)

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
      with {:ok, operation} <-
             start_operation("reconcile_node", Keyword.put(opts, :node_name, node_name)),
           {:ok, settled} <- Operations.await_settled(operation["operation_id"], 30_000) do
        {:ok, Operations.legacy_reconcile_result(settled)}
      end
    end
  end

  def drain_node(node_name, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :drain_node, [node_name, opts])
    else
      with {:ok, operation} <-
             start_operation("drain_node", Keyword.put(opts, :node_name, node_name)),
           {:ok, settled} <- Operations.await_settled(operation["operation_id"], 30_000) do
        {:ok, Operations.legacy_drain_result(settled)}
      end
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

  def list_services(opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :list_services, [opts])
    else
      MirrorNeuron.ServiceRegistry.list(opts)
    end
  end

  def resolve_service(name, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :resolve_service, [name, opts])
    else
      MirrorNeuron.ServiceRegistry.resolve(name, opts)
    end
  end

  def check_services(services, opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :check_services, [services, opts])
    else
      MirrorNeuron.ServicePreflight.check_services(services, opts)
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

  # Cancellation intent is written to the shared store before any work is
  # routed. In particular, do not forward this through a control node: an
  # unavailable owner must produce `cancellation_pending` immediately instead
  # of consuming the legacy job-control timeout.
  def cancel(job_id), do: request_durable_cancellation(job_id)

  def cancel_all do
    with {:ok, operation} <- start_operation("cancel_all_jobs"),
         {:ok, completed} <- Operations.await(operation["operation_id"], 30_000) do
      {:ok, Operations.legacy_cancel_all_result(completed)}
    end
  end

  # Operation intent, snapshots, and runner ownership are cluster-wide Redis
  # records. Starting locally works on both control and runtime nodes; the
  # runner lease prevents duplicate execution after a restart or rejoin.
  def start_operation(kind, opts \\ []), do: Operations.start(kind, opts)

  def operation(operation_id), do: Operations.get(operation_id)

  def operation_events(operation_id, after_sequence \\ 0),
    do: Operations.events(operation_id, after_sequence)

  def cleanup_jobs(opts \\ []) do
    if control_node?() do
      Control.call(__MODULE__, :cleanup_jobs, [opts])
    else
      Runtime.cleanup_jobs(opts)
    end
  end

  defp request_durable_cancellation(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status}} when status in ["completed", "failed", "cancelled"] ->
        {:ok, "cancelled"}

      {:ok, job} ->
        with {:ok, target_nodes} <- cancellation_target_nodes(job_id, job),
             {:ok, _request_state, cancellation} <-
               CancellationStore.request(job_id, target_nodes) do
          local_node = to_string(Node.self())

          if local_node in Map.get(cancellation, "target_nodes", []) and
               local_node not in Map.get(cancellation, "acknowledged_nodes", []) do
            _ = CancellationReconciler.reconcile_now(job_id)
          else
            CancellationReconciler.kick()
          end

          case RedisStore.fetch_job(job_id) do
            {:ok, %{"status" => "cancelled"}} -> {:ok, "cancelled"}
            _ -> {:ok, "cancellation_pending"}
          end
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp cancellation_target_nodes(job_id, job) do
    agents =
      case RedisStore.list_agents(job_id) do
        {:ok, records} -> records
        _ -> []
      end

    placement_nodes =
      job
      |> scheduler_placements()
      |> Enum.map(&(Map.get(&1, "node") || Map.get(&1, :node)))

    targets =
      agents
      |> Enum.map(&(Map.get(&1, "assigned_node") || Map.get(&1, :assigned_node)))
      |> Kernel.++(placement_nodes)
      |> Kernel.++([
        Map.get(job, "lease_owner") || Map.get(job, :lease_owner),
        get_in(job, ["lease", "owner_id"]) || get_in(job, [:lease, :owner_id])
      ])
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    {:ok, if(targets == [], do: [to_string(Node.self())], else: targets)}
  end

  defp scheduler_placements(job) do
    case get_in(job, ["scheduler", "placements"]) || get_in(job, [:scheduler, :placements]) do
      placements when is_list(placements) -> Enum.filter(placements, &is_map/1)
      _ -> []
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

      {:error, reason} = error ->
        if job_not_running_error?(reason) do
          call_runtime_by_job(job_id, function, args)
        else
          error
        end

      other ->
        other
    end
  end

  defp call_runtime_by_job(job_id, function, args),
    do: call_runtime_by_job(job_id, __MODULE__, function, args)

  defp call_runtime_by_job(job_id, module, function, args) do
    case RedisStore.list_agents(job_id) do
      {:ok, agents} ->
        agents
        |> Enum.map(& &1["assigned_node"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.reduce_while(
          job_not_running_result(job_id),
          fn node_name, _acc ->
            case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
              {:ok, node} ->
                _ = Node.connect(node)

                case :rpc.call(node, module, function, args, @cluster_job_control_timeout_ms) do
                  {:badrpc, reason} ->
                    {:halt,
                     {:error, {:cluster_job_control_unavailable, job_id, node_name, reason}}}

                  {:error, reason} = error ->
                    if job_not_running_error?(reason) do
                      {:cont, job_not_running_result(job_id)}
                    else
                      {:halt, error}
                    end

                  reply ->
                    {:halt, reply}
                end

              {:error, _reason} ->
                {:cont, job_not_running_result(job_id)}
            end
          end
        )

      {:error, reason} ->
        {:error, {:runtime_lookup_unavailable, job_id, reason}}
    end
  end

  defp job_not_running_result(job_id), do: {:error, {:job_not_running, job_id}}

  defp job_not_running_error?({:job_not_running, _job_id}), do: true

  defp job_not_running_error?(reason) when is_binary(reason),
    do: String.starts_with?(reason, "job ") and String.contains?(reason, "not running")

  defp job_not_running_error?(_reason), do: false
end
