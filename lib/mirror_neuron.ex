defmodule MirrorNeuron do
  alias MirrorNeuron.Cluster.Control
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Monitor
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Sandbox.{DockerJobSandbox, OpenShellJobSandbox}

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

  def cancel(job_id) do
    result =
      if control_node?() do
        call_control_or_runtime(job_id, :cancel, [job_id])
      else
        case Runtime.cancel_job(job_id) do
          {:error, reason} = error ->
            if job_not_running_error?(reason) do
              case call_runtime_by_job(job_id, Runtime, :cancel_job, [job_id]) do
                {:error, fallback_reason} when is_tuple(fallback_reason) ->
                  if runtime_lookup_unavailable_error?(fallback_reason),
                    do: error,
                    else: {:error, fallback_reason}

                other ->
                  other
              end
            else
              error
            end

          other ->
            other
        end
      end

    case result do
      {:error, reason} = error ->
        if cancel_force_fallback_error?(reason) do
          force_cancel_orphaned_job(job_id, Runtime.error_message(reason))
        else
          error
        end

      other ->
        other
    end
  end

  defp force_cancel_orphaned_job(job_id, original_error) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["pending", "running", "paused"] ->
        require Logger

        Logger.info(
          "Job #{job_id} process not found or did not respond, forcefully cancelling via Redis."
        )

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
        cleanup_job_sandboxes(job_id)

        MirrorNeuron.Runtime.EventBus.publish(job_id, %{
          type: :job_cancelled,
          reason: "forced cancellation",
          timestamp: Runtime.timestamp()
        })

        {:ok, "cancelled"}

      {:ok, %{"status" => "cancelled"}} ->
        cleanup_job_sandboxes(job_id)
        {:ok, "cancelled"}

      {:ok, _job} ->
        cleanup_job_sandboxes(job_id)
        {:error, "job is already in a terminal state"}

      {:error, reason} ->
        if is_binary(reason) and String.contains?(reason, "was not found") do
          {:error, reason}
        else
          {:error, original_error}
        end
    end
  end

  defp cleanup_job_sandboxes(job_id) do
    _ = OpenShellJobSandbox.cleanup_job_local(job_id)
    _ = DockerJobSandbox.cleanup_job_local(job_id)
    :ok
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

                case :rpc.call(node, module, function, args, 15_000) do
                  {:badrpc, _reason} ->
                    {:cont, job_not_running_result(job_id)}

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

  defp cancel_force_fallback_error?({:job_call_timeout, _job_id, _timeout_ms}), do: true
  defp cancel_force_fallback_error?(reason), do: job_not_running_error?(reason)

  defp runtime_lookup_unavailable_error?({:runtime_lookup_unavailable, _job_id, _reason}),
    do: true

  defp runtime_lookup_unavailable_error?(_reason), do: false
end
