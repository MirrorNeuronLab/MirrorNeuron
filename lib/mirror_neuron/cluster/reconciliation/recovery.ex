defmodule MirrorNeuron.Cluster.Reconciler.Recovery do
  @moduledoc "Applies recovery safety and lifecycle policy before restarting a job."

  alias MirrorNeuron.Cluster.Reconciler.Bundles
  alias MirrorNeuron.Cluster.Reconciler.Jobs
  alias MirrorNeuron.Cluster.Reconciler.NodeAvailability
  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Cluster.Reconciler.Policy
  alias MirrorNeuron.Cluster.Reconciler.Processes
  alias MirrorNeuron.Scheduler.RecoveryPlan
  alias MirrorNeuron.Runtime.RecoverySafety
  alias MirrorNeuron.Cluster.Reconciler.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Cluster.Reconciler.Status

  def reconcile_affected_job(job, failed_node, opts) do
    affected_agents = Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), failed_node)
    owner_match? = Jobs.lease_owner(job) == failed_node
    reason = Keyword.get(opts, :reason, "node #{failed_node} is unavailable")

    cond do
      not Jobs.cluster_recoverable?(job) ->
        Status.pause_for_review(job, reason, failed_node, affected_agents, opts)

      NodeAvailability.disconnected_grace_active?(failed_node, opts) ->
        Status.wait_for_disconnected_node(job, failed_node, affected_agents, reason, opts)

      owner_match? ->
        recover_whole_job(job, failed_node, reason, opts)

      Jobs.node_scoped_job?(job) ->
        Status.wait_for_node_scoped_recovery(job, failed_node, affected_agents, reason, opts)

      affected_agents == [] ->
        Results.skipped(job, "job has no scheduler placements on #{failed_node}")

      true ->
        recover_agents_or_fallback(job, failed_node, affected_agents, reason, opts)
    end
  end

  def reconcile_orphaned_job(job, opts) do
    job_id = job["job_id"]
    reason = Keyword.get(opts, :reason, "lost job lease")

    case Options.redis_store(opts).get_lease("job:#{job_id}") do
      {:ok, nil} ->
        if Jobs.safe_to_sweep?(job) do
          if Jobs.cluster_recoverable?(job) and
               NodeAvailability.disconnected_grace_active?(Jobs.lease_owner(job), opts) do
            Status.wait_for_disconnected_node(job, Jobs.lease_owner(job), [], reason, opts)
          else
            if Jobs.cluster_recoverable?(job) do
              recover_whole_job(job, Jobs.lease_owner(job), reason, opts)
            else
              Status.pause_for_review(
                job,
                "job is not configured for cluster recovery",
                Jobs.lease_owner(job),
                [],
                opts
              )
            end
          end
        else
          Results.skipped(job, "job is too recent to sweep")
        end

      {:ok, _lease} ->
        Results.skipped(job, "job lease is still active")

      {:error, reason} ->
        Results.failed(job, "could not inspect job lease: #{inspect(reason)}")
    end
  end

  def recover_agents_or_fallback(job, failed_node, affected_agents, reason, opts) do
    recover_whole_job(
      job,
      failed_node,
      "#{reason}; restarting the whole job attempt after losing #{Enum.join(affected_agents, ", ")}",
      opts
    )
  end

  defp recover_whole_job(job, failed_node, reason, opts) do
    job_id = job["job_id"]

    with {:ok, bundle} <- Bundles.load_recovery_bundle(job, opts),
         {:auto, _safety_reason} <- RecoverySafety.decision(job, bundle.manifest, []),
         :ok <-
           Policy.ensure_reschedule_policy_allows(job, Policy.whole_job_policy_agents(job), opts),
         {:ok, scheduler_plan} <-
           RecoveryPlan.recovery_scheduler_plan(
             bundle.manifest,
             RecoveryPlan.scheduler_opts(opts,
               exclude_nodes: List.wrap(failed_node),
               ignore_job_ids: [job_id]
             )
           ),
         :ok <- RecoveryPlan.validate_recovery_plan(scheduler_plan, failed_node, opts) do
      if Options.dry_run?(opts) do
        Results.recovered(job, "would restart job", %{mode: "job", scheduler: scheduler_plan})
      else
        :ok =
          Policy.record_reschedule_policy_attempt(
            job,
            Policy.whole_job_policy_agents(job),
            reason,
            opts
          )

        Status.mark_recovery(job, "rescheduling", reason, failed_node, [], opts)
        Processes.stop_existing_coordinator(job_id, opts)
        Processes.release_job_lease(job_id, job, opts)

        start_opts =
          opts
          |> Keyword.put(:restart_reason, reason)
          |> Keyword.put(
            :preferred_start_node,
            RecoveryPlan.preferred_start_node(scheduler_plan, failed_node)
          )

        case Processes.start_job_runner(job_id, bundle, job, scheduler_plan, start_opts) do
          :ok ->
            Status.mark_recovery(job, "rescheduled", reason, failed_node, [], opts)

            Status.publish(job_id, opts, %{
              type: :job_rescheduled,
              mode: "clean_restart",
              reason: reason,
              failed_node: failed_node,
              timestamp: Runtime.timestamp()
            })

            Results.recovered(job, "job restarted", %{mode: "job", scheduler: scheduler_plan})

          {:error, start_reason} ->
            Status.pause_for_review(
              job,
              "job reschedule failed: #{inspect(start_reason)}",
              failed_node,
              [],
              opts
            )
        end
      end
    else
      {:manual, safety_reason} ->
        Status.pause_for_review(job, safety_reason, failed_node, [], opts)

      {:blocked, safety_reason} ->
        Status.pause_for_review(job, safety_reason, failed_node, [], opts)

      {:placement_blocked, placement_reason} ->
        Status.block_recovery(job, placement_reason, failed_node, [], opts)

      {:policy_blocked, policy_reason} ->
        Status.pause_for_review(job, policy_reason, failed_node, [], opts)

      {:error, reason} ->
        Status.pause_for_review(job, inspect(reason), failed_node, [], opts)
    end
  end
end
