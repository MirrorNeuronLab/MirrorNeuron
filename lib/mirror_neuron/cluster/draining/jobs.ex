defmodule MirrorNeuron.Cluster.NodeDrainer.Jobs do
  @moduledoc "Selects drain candidates and migrates eligible jobs without consuming failure retry policy."

  alias MirrorNeuron.Cluster.NodeDrainer.Results
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Cluster.NodeDrainer.Settings

  @active_job_statuses ["pending", "running", "paused"]
  @system_job_types ["system", "sysbatch"]
  @completion_statuses ["complete", "completed", "succeeded", "failed", "cancelled", "stopped"]

  def process_job(job, context) do
    job_type = job_type(job)
    affected_agents = Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), context.node)
    owner_on_node? = lease_owner(job) == context.node

    cond do
      affected_agents == [] and not owner_on_node? ->
        Results.action(
          job,
          "skipped",
          "job has no placements on #{context.node}",
          affected_agents
        )

      context.ignore_system_jobs and job_type in @system_job_types ->
        Results.action(job, "ignored", "#{job_type} job is ignored during drain", affected_agents)

      job_type in ["batch", "sysbatch"] and not Settings.deadline_due?(context.deadline_at) ->
        Results.action(
          job,
          "waiting",
          "#{job_type} job is allowed to finish before drain deadline",
          affected_agents
        )

      true ->
        migrate_job(job, affected_agents, context)
    end
  end

  defp migrate_job(job, affected_agents, context) do
    reconciler_opts =
      context.opts
      |> Keyword.merge(
        reason: context.reason,
        trigger: "node_drain",
        node_status: "draining",
        only_job_ids: [job["job_id"]],
        dry_run: context.dry_run?,
        skip_reschedule_policy: true,
        skip_reschedule_policy_record: true,
        force: true
      )
      |> Keyword.update(:scheduler_opts, [exclude_nodes: [context.node]], fn scheduler_opts ->
        Keyword.merge(scheduler_opts, exclude_nodes: [context.node])
      end)

    case Settings.reconciler(context.opts).reconcile_node(context.node, reconciler_opts) do
      {:ok, %{} = result} ->
        classify_reconcile_result(job, affected_agents, result, context)

      {:error, reason} ->
        Results.action(
          job,
          "failed",
          "drain migration failed: #{inspect(reason)}",
          affected_agents
        )
    end
  end

  defp classify_reconcile_result(job, affected_agents, result, context) do
    cond do
      Map.get(result, :recovered, 0) > 0 or Map.get(result, "recovered", 0) > 0 ->
        Results.action(
          job,
          if(context.dry_run?, do: "would_migrate", else: "migrated"),
          if(context.dry_run?, do: "would migrate during drain", else: "migrated during drain"),
          affected_agents,
          %{"reconcile" => Settings.json_safe(result)}
        )

      Map.get(result, :blocked, 0) > 0 or Map.get(result, "blocked", 0) > 0 ->
        Results.action(job, "blocked", "drain migration is blocked", affected_agents, %{
          "reconcile" => Settings.json_safe(result)
        })

      Map.get(result, :paused, 0) > 0 or Map.get(result, "paused", 0) > 0 ->
        Results.action(
          job,
          "paused_for_review",
          "drain migration paused for review",
          affected_agents,
          %{
            "reconcile" => Settings.json_safe(result)
          }
        )

      Map.get(result, :failed, 0) > 0 or Map.get(result, "failed", 0) > 0 ->
        Results.action(job, "failed", "drain migration failed", affected_agents, %{
          "reconcile" => Settings.json_safe(result)
        })

      true ->
        Results.action(
          job,
          "skipped",
          "drain reconciliation did not move this job",
          affected_agents,
          %{
            "reconcile" => Settings.json_safe(result)
          }
        )
    end
  end

  def active_job?(job) do
    Map.get(job, "status") in @active_job_statuses and
      Map.get(job, "status") not in @completion_statuses
  end

  def filter_only_job_ids(jobs, nil), do: jobs

  def filter_only_job_ids(jobs, job_ids) do
    ids = job_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
    Enum.filter(jobs, &(Map.get(&1, "job_id") in ids))
  end

  def job_on_node?(job, node) do
    Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), node) != [] or
      Map.get(job, "lease_owner") == node or
      get_in(job, ["lease", "owner_id"]) == node
  end

  def job_type(job), do: job["job_type"] || get_in(job, ["scheduler", "job_type"]) || "batch"

  defp lease_owner(job), do: job["lease_owner"] || get_in(job, ["lease", "owner_id"])
end
