defmodule MirrorNeuron.Cluster.Reconciler.Operations do
  @moduledoc "Selects affected jobs and isolates failures during node and orphan reconciliation."

  alias MirrorNeuron.Cluster.Reconciler.EvaluationRecords
  alias MirrorNeuron.Cluster.Reconciler.Evaluations
  alias MirrorNeuron.Cluster.Reconciler.Jobs
  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Cluster.Reconciler.Recovery
  alias MirrorNeuron.Scheduler.RecoveryPlan
  alias MirrorNeuron.Cluster.Reconciler.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Cluster.Reconciler.Timing

  @active_statuses ["pending", "running", "paused"]
  @eval_retry_statuses ["pending", "blocked"]
  @empty_result %{
    checked: 0,
    recovered: 0,
    paused: 0,
    blocked: 0,
    skipped: 0,
    failed: 0,
    jobs: []
  }

  def reconcile_node(node, opts \\ []) do
    node_name = Options.node_name(node)

    opts = Keyword.put_new(opts, :trigger, "node_down")

    with {:ok, jobs} <- Jobs.list_reconciliation_jobs(opts) do
      result =
        jobs
        |> Enum.filter(&(Map.get(&1, "status") in @active_statuses))
        |> Jobs.filter_only_job_ids(Keyword.get(opts, :only_job_ids))
        |> Enum.reduce(@empty_result, fn job, acc ->
          result =
            Results.safe_job_result(job, "node reconciliation", fn ->
              cond do
                Jobs.paused_for_review?(job) ->
                  Results.skipped(job, "job is paused for review")

                Jobs.affected_by_node?(job, node_name) ->
                  with {:ok, full_job} <- Jobs.fetch_reconciliation_job(job, opts) do
                    enqueue_or_run_affected_job(full_job, node_name, opts)
                  else
                    {:error, reason} ->
                      Results.failed(
                        job,
                        "could not load job for node reconciliation: #{inspect(reason)}"
                      )
                  end

                true ->
                  Results.skipped(job, "job is not affected by #{node_name}")
              end
            end)

          Results.record(acc, result)
        end)

      {:ok, Results.finalize_result(result)}
    end
  end

  def reconcile_job(job_id, node, opts \\ []) when is_binary(job_id) do
    node_name = Options.node_name(node)
    opts = Keyword.put_new(opts, :trigger, "operator_reconcile")

    with {:ok, job} <- Options.redis_store(opts).fetch_job(job_id) do
      result =
        Results.safe_job_result(job, "node reconciliation", fn ->
          cond do
            Map.get(job, "status") not in @active_statuses ->
              Results.skipped(job, "job is #{Map.get(job, "status")}")

            Jobs.paused_for_review?(job) ->
              Results.skipped(job, "job is paused for review")

            not Jobs.affected_by_node?(job, node_name) ->
              Results.skipped(job, "job is not affected by #{node_name}")

            true ->
              with {:ok, full_job} <- Jobs.fetch_reconciliation_job(job, opts) do
                enqueue_or_run_affected_job(full_job, node_name, opts)
              else
                {:error, reason} ->
                  Results.failed(
                    job,
                    "could not load job for node reconciliation: #{inspect(reason)}"
                  )
              end
          end
        end)

      {:ok, result}
    end
  end

  def reschedule_agents(job_id, agent_ids, opts \\ []) do
    opts = Keyword.put_new(opts, :trigger, "restart_exhausted")

    with {:ok, job} <- Options.redis_store(opts).fetch_job(job_id) do
      affected_agents = List.wrap(agent_ids) |> Enum.map(&to_string/1) |> Enum.uniq()
      failed_nodes = RecoveryPlan.current_target_nodes(job, affected_agents)
      reason = Keyword.get(opts, :reason, "restart policy exhausted")

      result =
        cond do
          Map.get(job, "status") not in @active_statuses ->
            Results.skipped(job, "job is #{Map.get(job, "status")}")

          Jobs.paused_for_review?(job) ->
            Results.skipped(job, "job is paused for review")

          affected_agents == [] ->
            Results.skipped(job, "no affected agents requested")

          Options.dry_run?(opts) or Keyword.has_key?(opts, :eval) ->
            Recovery.recover_agents_or_fallback(job, failed_nodes, affected_agents, reason, opts)

          true ->
            Evaluations.enqueue_and_process_eval(
              job,
              Keyword.fetch!(opts, :trigger),
              failed_nodes,
              affected_agents,
              reason,
              opts
            )
        end

      {:ok, Results.finalize_result(Results.record(@empty_result, result))}
    end
  end

  def sweep_orphaned_jobs(owner_node \\ nil, opts \\ []) do
    owner_node = if is_nil(owner_node), do: nil, else: Options.node_name(owner_node)
    opts = Keyword.put_new(opts, :trigger, "lease_lost")

    with {:ok, jobs} <- Jobs.list_reconciliation_jobs(opts) do
      result =
        jobs
        |> Enum.filter(&(Map.get(&1, "status") in @active_statuses))
        |> Enum.filter(fn job -> is_nil(owner_node) or Jobs.lease_owner(job) == owner_node end)
        |> Enum.reduce(@empty_result, fn job, acc ->
          result =
            Results.safe_job_result(job, "orphan sweep", fn ->
              enqueue_or_run_orphaned_job(job, opts)
            end)

          Results.record(acc, result)
        end)

      {:ok, Results.finalize_result(result)}
    end
  end

  def process_due_evals(opts \\ []) do
    with {:ok, evals} <- EvaluationRecords.list_recovery_evals(opts, @eval_retry_statuses) do
      result =
        evals
        |> Enum.filter(&Timing.due_eval?/1)
        |> Enum.reduce(@empty_result, fn eval, acc ->
          result =
            Evaluations.safe_eval_result(eval, opts, fn ->
              Evaluations.process_recovery_eval(eval, opts)
            end)

          Results.record(acc, result)
        end)

      {:ok, Results.finalize_result(result)}
    end
  end

  def wake_blocked_evals(opts \\ []) do
    reason = Keyword.get(opts, :reason, "cluster capacity changed")

    with {:ok, evals} <- EvaluationRecords.list_recovery_evals(opts, ["blocked"]) do
      evals
      |> Enum.each(fn eval ->
        _ =
          EvaluationRecords.update_recovery_eval(
            Map.fetch!(eval, "eval_id"),
            %{
              "status" => "pending",
              "wait_until" => nil,
              "wake_reason" => reason,
              "updated_at" => Runtime.timestamp()
            },
            opts
          )
      end)

      process_due_evals(opts)
    end
  end

  defp enqueue_or_run_affected_job(job, failed_node, opts) do
    if Options.dry_run?(opts) or Keyword.has_key?(opts, :eval) do
      Recovery.reconcile_affected_job(job, failed_node, opts)
    else
      affected_agents = Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), failed_node)
      reason = Keyword.get(opts, :reason, "node #{failed_node} is unavailable")

      Evaluations.enqueue_and_process_eval(
        job,
        Keyword.fetch!(opts, :trigger),
        failed_node,
        affected_agents,
        reason,
        opts
      )
    end
  end

  defp enqueue_or_run_orphaned_job(job, opts) do
    cond do
      Jobs.paused_for_review?(job) ->
        Results.skipped(job, "job is paused for review")

      not Jobs.cluster_recoverable?(job) ->
        Results.skipped(job, "job is managed by local recovery")

      true ->
        case Options.redis_store(opts).get_lease("job:#{job["job_id"]}") do
          {:ok, nil} ->
            with {:ok, full_job} <- Jobs.fetch_reconciliation_job(job, opts) do
              if Options.dry_run?(opts) or Keyword.has_key?(opts, :eval) do
                Recovery.reconcile_orphaned_job(full_job, opts)
              else
                failed_node = Jobs.lease_owner(full_job)
                reason = Keyword.get(opts, :reason, "lost job lease")

                Evaluations.enqueue_and_process_eval(
                  full_job,
                  Keyword.fetch!(opts, :trigger),
                  failed_node,
                  [],
                  reason,
                  opts
                )
              end
            else
              {:error, reason} ->
                Results.failed(job, "could not load job for orphan sweep: #{inspect(reason)}")
            end

          {:ok, _lease} ->
            Results.skipped(job, "job lease is still active")

          {:error, reason} ->
            Results.failed(job, "could not inspect job lease: #{inspect(reason)}")
        end
    end
  end
end
