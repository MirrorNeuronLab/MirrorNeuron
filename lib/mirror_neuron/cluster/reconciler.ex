defmodule MirrorNeuron.Cluster.Reconciler do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{EventBus, JobRunner, LifecyclePolicy, RecoverySafety}
  alias MirrorNeuron.Scheduler

  @active_statuses ["pending", "running", "paused"]
  @active_node_statuses ["healthy", "joining"]
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
    node_name = node_name(node)

    opts = Keyword.put_new(opts, :trigger, "node_down")

    with {:ok, jobs} <- redis_store(opts).list_jobs() do
      result =
        jobs
        |> Enum.filter(&(Map.get(&1, "status") in @active_statuses))
        |> filter_only_job_ids(Keyword.get(opts, :only_job_ids))
        |> Enum.reduce(@empty_result, fn job, acc ->
          if affected_by_node?(job, node_name) do
            record(acc, enqueue_or_run_affected_job(job, node_name, opts))
          else
            record(acc, skipped(job, "job is not affected by #{node_name}"))
          end
        end)

      {:ok, finalize_result(result)}
    end
  end

  def reschedule_agents(job_id, agent_ids, opts \\ []) do
    opts = Keyword.put_new(opts, :trigger, "restart_exhausted")

    with {:ok, job} <- redis_store(opts).fetch_job(job_id) do
      affected_agents = List.wrap(agent_ids) |> Enum.map(&to_string/1) |> Enum.uniq()
      failed_nodes = current_target_nodes(job, affected_agents)
      reason = Keyword.get(opts, :reason, "restart policy exhausted")

      result =
        cond do
          Map.get(job, "status") not in @active_statuses ->
            skipped(job, "job is #{Map.get(job, "status")}")

          affected_agents == [] ->
            skipped(job, "no affected agents requested")

          dry_run?(opts) or Keyword.has_key?(opts, :eval) ->
            recover_agents_or_fallback(job, failed_nodes, affected_agents, reason, opts)

          true ->
            enqueue_and_process_eval(
              job,
              Keyword.fetch!(opts, :trigger),
              failed_nodes,
              affected_agents,
              reason,
              opts
            )
        end

      {:ok, finalize_result(record(@empty_result, result))}
    end
  end

  def sweep_orphaned_jobs(owner_node \\ nil, opts \\ []) do
    owner_node = if is_nil(owner_node), do: nil, else: node_name(owner_node)
    opts = Keyword.put_new(opts, :trigger, "lease_lost")

    with {:ok, jobs} <- redis_store(opts).list_jobs() do
      result =
        jobs
        |> Enum.filter(&(Map.get(&1, "status") in @active_statuses))
        |> Enum.filter(fn job -> is_nil(owner_node) or lease_owner(job) == owner_node end)
        |> Enum.reduce(@empty_result, fn job, acc ->
          record(acc, enqueue_or_run_orphaned_job(job, opts))
        end)

      {:ok, finalize_result(result)}
    end
  end

  def process_due_evals(opts \\ []) do
    with {:ok, evals} <- list_recovery_evals(opts) do
      result =
        evals
        |> Enum.filter(&due_eval?/1)
        |> Enum.reduce(@empty_result, fn eval, acc ->
          record(acc, process_recovery_eval(eval, opts))
        end)

      {:ok, finalize_result(result)}
    end
  end

  def wake_blocked_evals(opts \\ []) do
    reason = Keyword.get(opts, :reason, "cluster capacity changed")

    with {:ok, evals} <- list_recovery_evals(opts) do
      evals
      |> Enum.filter(&(Map.get(&1, "status") == "blocked"))
      |> Enum.each(fn eval ->
        _ =
          update_recovery_eval(
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
    if dry_run?(opts) or Keyword.has_key?(opts, :eval) do
      reconcile_affected_job(job, failed_node, opts)
    else
      affected_agents = Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), failed_node)
      reason = Keyword.get(opts, :reason, "node #{failed_node} is unavailable")

      enqueue_and_process_eval(
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
    if dry_run?(opts) or Keyword.has_key?(opts, :eval) do
      reconcile_orphaned_job(job, opts)
    else
      failed_node = lease_owner(job)
      reason = Keyword.get(opts, :reason, "lost job lease")
      enqueue_and_process_eval(job, Keyword.fetch!(opts, :trigger), failed_node, [], reason, opts)
    end
  end

  defp enqueue_and_process_eval(job, trigger, failed_node, affected_agents, reason, opts) do
    trigger = to_string(trigger)

    case find_active_eval(job["job_id"], trigger, failed_node, opts) do
      %{"status" => "running"} = eval ->
        skipped(job, "recovery eval #{eval["eval_id"]} is already running")

      %{"status" => "blocked"} = eval ->
        if due_eval?(eval) or Keyword.get(opts, :force, false) do
          eval
          |> Map.put("status", "pending")
          |> Map.put("updated_at", Runtime.timestamp())
          |> persist_recovery_eval(opts)
          |> case do
            {:ok, persisted} ->
              maybe_process_eval(persisted, opts)

            {:error, persist_reason} ->
              failed(job, "could not persist recovery eval: #{inspect(persist_reason)}")
          end
        else
          blocked(job, Map.get(eval, "block_reason") || reason, %{
            eval_id: eval["eval_id"],
            wait_until: Map.get(eval, "wait_until"),
            failed_node: failed_node,
            affected_agents: affected_agents
          })
        end

      existing when is_map(existing) ->
        eval =
          existing
          |> Map.merge(%{
            "trigger" => trigger,
            "reason" => reason,
            "failed_node" => failed_node,
            "affected_agents" => affected_agents,
            "job" => job,
            "status" => "pending",
            "updated_at" => Runtime.timestamp()
          })

        with {:ok, persisted} <- persist_recovery_eval(eval, opts) do
          maybe_process_eval(persisted, opts)
        else
          {:error, persist_reason} ->
            failed(job, "could not persist recovery eval: #{inspect(persist_reason)}")
        end

      nil ->
        eval = new_recovery_eval(job, trigger, failed_node, affected_agents, reason)

        with {:ok, persisted} <- persist_recovery_eval(eval, opts) do
          maybe_process_eval(persisted, opts)
        else
          {:error, persist_reason} ->
            failed(job, "could not persist recovery eval: #{inspect(persist_reason)}")
        end
    end
  end

  defp maybe_process_eval(eval, opts) do
    if Keyword.get(opts, :defer, false) do
      skipped(eval_job(eval), "queued recovery eval #{eval["eval_id"]}")
    else
      process_recovery_eval(eval, opts)
    end
  end

  defp process_recovery_eval(%{"status" => status} = eval, opts)
       when status in @eval_retry_statuses do
    if due_eval?(eval) or Keyword.get(opts, :force, false) do
      do_process_recovery_eval(eval, opts)
    else
      blocked(eval_job(eval), Map.get(eval, "block_reason") || "recovery eval is waiting", %{
        eval_id: eval["eval_id"],
        wait_until: Map.get(eval, "wait_until"),
        failed_node: Map.get(eval, "failed_node"),
        affected_agents: Map.get(eval, "affected_agents", [])
      })
    end
  end

  defp process_recovery_eval(eval, _opts) do
    skipped(eval_job(eval), "recovery eval #{eval["eval_id"]} is #{eval["status"]}")
  end

  defp do_process_recovery_eval(eval, opts) do
    attempt = recovery_eval_attempt(eval) + 1
    running_at = Runtime.timestamp()

    running_eval =
      eval
      |> Map.put("status", "running")
      |> Map.put("attempt", attempt)
      |> Map.put("started_at", running_at)
      |> Map.put("updated_at", running_at)
      |> Map.put("history", append_eval_history(eval, "running", "attempt #{attempt} started"))

    _ = persist_recovery_eval(running_eval, opts)

    result =
      case fetch_eval_job(running_eval, opts) do
        {:ok, job} ->
          run_recovery_eval(running_eval, job, opts)

        {:error, reason} ->
          failed(eval_job(running_eval), "could not load recovery eval job: #{inspect(reason)}")
      end

    finalize_recovery_eval(running_eval, result, opts)
    result
  end

  defp run_recovery_eval(eval, job, opts) do
    eval_opts =
      opts
      |> Keyword.put(:eval, eval)
      |> Keyword.put(:reason, Map.get(eval, "reason") || Keyword.get(opts, :reason))

    case Map.get(eval, "trigger") do
      "lease_lost" ->
        reconcile_orphaned_job(job, eval_opts)

      "restart_exhausted" ->
        recover_agents_or_fallback(
          job,
          Map.get(eval, "failed_node"),
          Map.get(eval, "affected_agents", []),
          Map.get(eval, "reason") || "restart policy exhausted",
          eval_opts
        )

      _trigger ->
        reconcile_affected_job(job, Map.get(eval, "failed_node"), eval_opts)
    end
  end

  defp finalize_recovery_eval(eval, result, opts) do
    now = Runtime.timestamp()
    {status, wait_until} = eval_status_for_result(eval, result, opts)

    updates =
      %{
        "status" => status,
        "result" => stringify_result(result),
        "block_reason" => if(status == "blocked", do: result.reason, else: nil),
        "wait_until" => wait_until,
        "completed_at" => if(status in ["complete", "failed"], do: now, else: nil),
        "updated_at" => now,
        "history" => append_eval_history(eval, status, result.reason)
      }

    _ = update_recovery_eval(eval["eval_id"], updates, opts)
    :ok
  end

  defp eval_status_for_result(_eval, %{action: :recovered}, _opts), do: {"complete", nil}
  defp eval_status_for_result(_eval, %{action: :paused_for_review}, _opts), do: {"complete", nil}
  defp eval_status_for_result(_eval, %{action: :skipped}, _opts), do: {"complete", nil}
  defp eval_status_for_result(_eval, %{action: :failed}, _opts), do: {"failed", nil}

  defp eval_status_for_result(eval, %{action: :blocked, wait_until: wait_until}, opts),
    do: {"blocked", wait_until || retry_wait_until(eval, opts)}

  defp eval_status_for_result(eval, %{action: :blocked}, opts),
    do: {"blocked", retry_wait_until(eval, opts)}

  defp eval_status_for_result(_eval, _result, _opts), do: {"failed", nil}

  defp new_recovery_eval(job, trigger, failed_node, affected_agents, reason) do
    now = Runtime.timestamp()
    job_id = job["job_id"]

    %{
      "eval_id" => "rec-#{job_id}-#{System.unique_integer([:positive, :monotonic])}",
      "job_id" => job_id,
      "trigger" => trigger,
      "status" => "pending",
      "reason" => reason,
      "failed_node" => failed_node,
      "affected_agents" => affected_agents,
      "attempt" => 0,
      "job" => job,
      "created_at" => now,
      "updated_at" => now,
      "history" => []
    }
  end

  defp find_active_eval(job_id, trigger, failed_node, opts) do
    with {:ok, evals} <- list_recovery_evals(opts) do
      Enum.find(evals, fn eval ->
        Map.get(eval, "job_id") == job_id and
          Map.get(eval, "trigger") == to_string(trigger) and
          Map.get(eval, "failed_node") == failed_node and
          Map.get(eval, "status") in ["pending", "running", "blocked"]
      end)
    else
      _ -> nil
    end
  end

  defp list_recovery_evals(opts) do
    store = redis_store(opts)

    if function_exported?(store, :list_recovery_evals, 0) do
      store.list_recovery_evals()
    else
      {:ok, []}
    end
  end

  defp persist_recovery_eval(%{"eval_id" => eval_id} = eval, opts) do
    store = redis_store(opts)

    if function_exported?(store, :persist_recovery_eval, 2) do
      store.persist_recovery_eval(eval_id, eval)
    else
      {:ok, eval}
    end
  end

  defp update_recovery_eval(eval_id, updates, opts) do
    store = redis_store(opts)

    if function_exported?(store, :update_recovery_eval, 2) do
      store.update_recovery_eval(eval_id, updates)
    else
      {:ok, updates}
    end
  end

  defp fetch_eval_job(eval, opts) do
    store = redis_store(opts)
    job_id = Map.get(eval, "job_id")

    cond do
      function_exported?(store, :fetch_job, 1) ->
        store.fetch_job(job_id)

      is_map(Map.get(eval, "job")) ->
        {:ok, Map.get(eval, "job")}

      true ->
        {:error, :missing_eval_job}
    end
  end

  defp eval_job(eval), do: Map.get(eval, "job") || %{"job_id" => Map.get(eval, "job_id")}

  defp due_eval?(eval) do
    Map.get(eval, "status") in @eval_retry_statuses and wait_due?(Map.get(eval, "wait_until"))
  end

  defp wait_due?(nil), do: true
  defp wait_due?(""), do: true

  defp wait_due?(wait_until) when is_binary(wait_until) do
    case DateTime.from_iso8601(wait_until) do
      {:ok, dt, _offset} -> DateTime.compare(dt, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp wait_due?(_wait_until), do: true

  defp recovery_eval_attempt(eval), do: integer_value(Map.get(eval, "attempt"), 0)

  defp append_eval_history(eval, status, reason) do
    entry = %{
      "status" => status,
      "reason" => reason,
      "timestamp" => Runtime.timestamp()
    }

    eval
    |> Map.get("history", [])
    |> List.wrap()
    |> Kernel.++([entry])
    |> Enum.take(-20)
  end

  defp retry_wait_until(eval, opts) do
    attempt = max(recovery_eval_attempt(eval), 1)

    base =
      Keyword.get(
        opts,
        :retry_base_ms,
        config_positive_integer("MN_RECOVERY_EVAL_RETRY_BASE_MS", 5_000)
      )

    max_delay =
      Keyword.get(
        opts,
        :retry_max_ms,
        config_positive_integer("MN_RECOVERY_EVAL_RETRY_MAX_MS", 60_000)
      )

    delay = min(max_delay, trunc(base * :math.pow(2, attempt - 1)))
    iso_after(delay)
  end

  defp reconcile_affected_job(job, failed_node, opts) do
    affected_agents = Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), failed_node)
    owner_match? = lease_owner(job) == failed_node
    reason = Keyword.get(opts, :reason, "node #{failed_node} is unavailable")

    cond do
      not cluster_recoverable?(job) ->
        pause_for_review(job, reason, failed_node, affected_agents, opts)

      disconnected_grace_active?(failed_node, opts) ->
        wait_for_disconnected_node(job, failed_node, affected_agents, reason, opts)

      owner_match? ->
        recover_whole_job(job, failed_node, reason, opts)

      node_scoped_job?(job) ->
        wait_for_node_scoped_recovery(job, failed_node, affected_agents, reason, opts)

      affected_agents == [] ->
        skipped(job, "job has no scheduler placements on #{failed_node}")

      true ->
        recover_agents_or_fallback(job, failed_node, affected_agents, reason, opts)
    end
  end

  defp reconcile_orphaned_job(job, opts) do
    job_id = job["job_id"]
    reason = Keyword.get(opts, :reason, "lost job lease")

    case redis_store(opts).get_lease("job:#{job_id}") do
      {:ok, nil} ->
        if safe_to_sweep?(job) do
          if cluster_recoverable?(job) and disconnected_grace_active?(lease_owner(job), opts) do
            wait_for_disconnected_node(job, lease_owner(job), [], reason, opts)
          else
            if cluster_recoverable?(job) do
              recover_whole_job(job, lease_owner(job), reason, opts)
            else
              pause_for_review(
                job,
                "job is not configured for cluster recovery",
                lease_owner(job),
                [],
                opts
              )
            end
          end
        else
          skipped(job, "job is too recent to sweep")
        end

      {:ok, _lease} ->
        skipped(job, "job lease is still active")

      {:error, reason} ->
        failed(job, "could not inspect job lease: #{inspect(reason)}")
    end
  end

  defp recover_agents_or_fallback(job, failed_node, affected_agents, reason, opts) do
    job_id = job["job_id"]

    case coordinator_pid(job_id, opts) do
      {:ok, pid} ->
        recover_agents(job, failed_node, affected_agents, reason, pid, opts)

      :not_found ->
        case redis_store(opts).get_lease("job:#{job_id}") do
          {:ok, nil} ->
            recover_whole_job(job, failed_node, "job coordinator is unavailable", opts)

          {:ok, _lease} ->
            pause_for_review(
              job,
              "job coordinator is unavailable while the job lease is still active",
              failed_node,
              affected_agents,
              opts
            )

          {:error, lease_reason} ->
            failed(job, "could not inspect job lease: #{inspect(lease_reason)}")
        end
    end
  end

  defp recover_agents(job, failed_node, affected_agents, reason, coordinator, opts) do
    job_id = job["job_id"]

    with {:ok, bundle} <- load_recovery_bundle(job, opts),
         {:ok, agents} <- redis_store(opts).list_agents(job_id),
         {:auto, _safety_reason} <-
           RecoverySafety.decision(job, bundle.manifest, agents, agent_ids: affected_agents),
         :ok <- ensure_reschedule_policy_allows(job, affected_agents, opts),
         {:ok, partial_plan} <-
           recovery_scheduler_plan(
             bundle.manifest,
             scheduler_opts(opts,
               exclude_nodes: List.wrap(failed_node),
               ignore_job_ids: [job_id],
               only_agent_ids: affected_agents
             )
           ),
         :ok <- validate_recovery_plan(partial_plan, failed_node, opts) do
      scheduler_plan = Scheduler.merge_plan(Map.get(job, "scheduler", %{}), partial_plan)

      if dry_run?(opts) do
        recovered(job, "would reschedule agents", %{
          mode: "agents",
          affected_agents: affected_agents,
          scheduler: scheduler_plan
        })
      else
        :ok = record_reschedule_policy_attempt(job, affected_agents, reason, opts)
        mark_recovery(job, "rescheduling", reason, failed_node, affected_agents, opts)

        case GenServer.call(
               coordinator,
               {:reschedule_agents, affected_agents, scheduler_plan, reason},
               60_000
             ) do
          {:ok, payload} ->
            mark_recovery(job, "rescheduled", reason, failed_node, affected_agents, opts)

            publish(job_id, opts, %{
              type: :job_agents_rescheduled,
              reason: reason,
              failed_node: failed_node,
              affected_agents: affected_agents,
              timestamp: Runtime.timestamp()
            })

            recovered(job, "agents rescheduled", Map.merge(%{mode: "agents"}, payload))

          {:error, reschedule_reason} ->
            pause_for_review(
              job,
              "agent reschedule failed: #{inspect(reschedule_reason)}",
              failed_node,
              affected_agents,
              opts
            )
        end
      end
    else
      {:manual, safety_reason} ->
        pause_for_review(job, safety_reason, failed_node, affected_agents, opts)

      {:blocked, safety_reason} ->
        pause_for_review(job, safety_reason, failed_node, affected_agents, opts)

      {:placement_blocked, placement_reason} ->
        block_recovery(job, placement_reason, failed_node, affected_agents, opts)

      {:policy_blocked, policy_reason} ->
        pause_for_review(job, policy_reason, failed_node, affected_agents, opts)

      {:error, reason} ->
        pause_for_review(job, inspect(reason), failed_node, affected_agents, opts)
    end
  catch
    :exit, reason ->
      pause_for_review(
        job,
        "agent reschedule call failed: #{inspect(reason)}",
        failed_node,
        affected_agents,
        opts
      )
  end

  defp recover_whole_job(job, failed_node, reason, opts) do
    job_id = job["job_id"]

    with {:ok, bundle} <- load_recovery_bundle(job, opts),
         {:ok, agents} <- redis_store(opts).list_agents(job_id),
         {:auto, _safety_reason} <- RecoverySafety.decision(job, bundle.manifest, agents),
         :ok <- ensure_reschedule_policy_allows(job, whole_job_policy_agents(job), opts),
         {:ok, scheduler_plan} <-
           recovery_scheduler_plan(
             bundle.manifest,
             scheduler_opts(opts,
               exclude_nodes: List.wrap(failed_node),
               ignore_job_ids: [job_id]
             )
           ),
         :ok <- validate_recovery_plan(scheduler_plan, failed_node, opts) do
      if dry_run?(opts) do
        recovered(job, "would restart job", %{mode: "job", scheduler: scheduler_plan})
      else
        :ok = record_reschedule_policy_attempt(job, whole_job_policy_agents(job), reason, opts)
        mark_recovery(job, "rescheduling", reason, failed_node, [], opts)
        release_job_lease(job_id, job, opts)

        case start_job_runner(job_id, bundle, job, scheduler_plan, opts) do
          :ok ->
            mark_recovery(job, "rescheduled", reason, failed_node, [], opts)

            publish(job_id, opts, %{
              type: :job_rescheduled,
              reason: reason,
              failed_node: failed_node,
              timestamp: Runtime.timestamp()
            })

            recovered(job, "job restarted", %{mode: "job", scheduler: scheduler_plan})

          {:error, start_reason} ->
            pause_for_review(
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
        pause_for_review(job, safety_reason, failed_node, [], opts)

      {:blocked, safety_reason} ->
        pause_for_review(job, safety_reason, failed_node, [], opts)

      {:placement_blocked, placement_reason} ->
        block_recovery(job, placement_reason, failed_node, [], opts)

      {:policy_blocked, policy_reason} ->
        pause_for_review(job, policy_reason, failed_node, [], opts)

      {:error, reason} ->
        pause_for_review(job, inspect(reason), failed_node, [], opts)
    end
  end

  defp pause_for_review(job, reason, failed_node, affected_agents, opts) do
    if dry_run?(opts) do
      paused(job, reason, %{failed_node: failed_node, affected_agents: affected_agents})
    else
      mark_recovery(job, "paused_for_review", reason, failed_node, affected_agents, opts,
        status: "paused",
        requires_review?: true
      )

      publish(job["job_id"], opts, %{
        type: :job_paused_for_manual_restart,
        reason: reason,
        failed_node: failed_node,
        affected_agents: affected_agents,
        timestamp: Runtime.timestamp()
      })

      paused(job, reason, %{failed_node: failed_node, affected_agents: affected_agents})
    end
  end

  defp block_recovery(job, reason, failed_node, affected_agents, opts, block_opts \\ []) do
    wait_until =
      Keyword.get(block_opts, :wait_until) ||
        retry_wait_until(Keyword.get(opts, :eval, %{}), opts)

    status = Keyword.get(block_opts, :status, "blocked_no_placement")

    if dry_run?(opts) do
      blocked(job, reason, %{
        failed_node: failed_node,
        affected_agents: affected_agents,
        wait_until: wait_until
      })
    else
      mark_recovery(job, status, reason, failed_node, affected_agents, opts,
        wait_until: wait_until,
        requires_review?: false
      )

      publish(job["job_id"], opts, %{
        type: :job_recovery_blocked,
        reason: reason,
        failed_node: failed_node,
        affected_agents: affected_agents,
        wait_until: wait_until,
        timestamp: Runtime.timestamp()
      })

      blocked(job, reason, %{
        failed_node: failed_node,
        affected_agents: affected_agents,
        wait_until: wait_until
      })
    end
  end

  defp wait_for_disconnected_node(job, failed_node, affected_agents, reason, opts) do
    wait_until =
      disconnected_wait_until(failed_node, opts) ||
        retry_wait_until(Keyword.get(opts, :eval, %{}), opts)

    wait_reason =
      "node #{failed_node} is inside its disconnect grace window; waiting before relocating work"

    block_recovery(job, wait_reason, failed_node, affected_agents, opts,
      status: "waiting_for_node",
      wait_until: wait_until,
      reason: reason
    )
  end

  defp wait_for_node_scoped_recovery(job, failed_node, affected_agents, reason, opts) do
    wait_reason =
      "#{job_type(job)} allocations are scoped to their original runtime node; " <>
        "waiting for #{failed_node} to recover instead of relocating them"

    unless dry_run?(opts) do
      wait_until = retry_wait_until(Keyword.get(opts, :eval, %{}), opts)

      mark_recovery(job, "waiting_for_node", wait_reason, failed_node, affected_agents, opts,
        wait_until: wait_until
      )

      publish(job["job_id"], opts, %{
        type: :job_node_scoped_recovery_waiting,
        reason: reason,
        detail: wait_reason,
        failed_node: failed_node,
        affected_agents: affected_agents,
        wait_until: wait_until,
        timestamp: Runtime.timestamp()
      })
    end

    blocked(job, wait_reason, %{
      failed_node: failed_node,
      affected_agents: affected_agents,
      wait_until: retry_wait_until(Keyword.get(opts, :eval, %{}), opts)
    })
  end

  defp mark_recovery(job, status, reason, failed_node, affected_agents, opts, mark_opts \\ []) do
    now = Runtime.timestamp()
    requires_review? = Keyword.get(mark_opts, :requires_review?, false)
    eval = Keyword.get(opts, :eval, %{})
    wait_until = Keyword.get(mark_opts, :wait_until)

    recovery =
      %{
        "status" => status,
        "reason" => reason,
        "requires_review" => requires_review?,
        "can_resume" => requires_review?,
        "failed_node" => failed_node,
        "affected_agents" => affected_agents,
        "wait_until" => wait_until,
        "eval_id" => Map.get(eval, "eval_id"),
        "attempt" => Map.get(eval, "attempt"),
        "updated_at" => now
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    updates =
      %{
        "recovery" => recovery,
        "recovery_status" => status,
        "recovery_reason" => reason,
        "recovery_requires_review" => requires_review?
      }
      |> maybe_put("status", Keyword.get(mark_opts, :status))
      |> maybe_put("recovery_wait_until", wait_until)

    defaults = job_defaults(job, now)

    case redis_store(opts).persist_terminal_job(job["job_id"], updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist reconciliation status for #{job["job_id"]}: #{inspect(persist_reason)}"
        )
    end
  end

  defp recovery_scheduler_plan(manifest, opts) do
    case Scheduler.plan(manifest, opts) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:placement_blocked, format_reason(reason)}
    end
  end

  defp validate_recovery_plan(%{"placements" => placements}, failed_node, opts)
       when is_list(placements) do
    nodes_by_name =
      opts
      |> validation_nodes()
      |> Enum.into(%{}, fn node -> {validation_node_name(node), node} end)
      |> Map.reject(fn {name, _node} -> is_nil(name) end)

    if map_size(nodes_by_name) == 0 do
      :ok
    else
      placements
      |> Enum.reduce_while(:ok, fn placement, :ok ->
        target = Map.get(placement, "node")
        node = Map.get(nodes_by_name, target)
        status = validation_node_status(node)

        cond do
          is_nil(target) ->
            {:halt, {:placement_blocked, "scheduler placement is missing a target node"}}

          target in List.wrap(failed_node) ->
            {:halt,
             {:placement_blocked, "final validation rejected placement on failed node #{target}"}}

          is_nil(node) ->
            {:halt,
             {:placement_blocked, "target node #{target} is not visible during final validation"}}

          status not in @active_node_statuses ->
            {:halt,
             {:placement_blocked,
              "target node #{target} is #{status || "unknown"} during final validation"}}

          validation_node_scheduling_eligible?(node) == false ->
            {:halt,
             {:placement_blocked,
              "target node #{target} is scheduling-ineligible during final validation"}}

          true ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp validate_recovery_plan(_plan, _failed_node, _opts),
    do: {:placement_blocked, "scheduler plan is missing placements"}

  defp validation_nodes(opts) do
    scheduler_opts = Keyword.get(opts, :scheduler_opts, [])

    nodes =
      Keyword.get(opts, :validation_nodes) ||
        Keyword.get(scheduler_opts, :nodes) ||
        default_validation_nodes()

    nodes
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp default_validation_nodes do
    case MirrorNeuron.inspect_nodes() do
      nodes when is_list(nodes) -> nodes
      _ -> []
    end
  rescue
    _ -> []
  catch
    _kind, _reason -> []
  end

  defp validation_node_name(node) do
    Map.get(node, "name") || Map.get(node, :name) || Map.get(node, "node") || Map.get(node, :node)
  end

  defp validation_node_status(nil), do: nil

  defp validation_node_status(node),
    do: Map.get(node, "status") || Map.get(node, :status) || "healthy"

  defp validation_node_scheduling_eligible?(node) do
    cond do
      is_nil(node) -> false
      Map.has_key?(node, "scheduling_eligible") -> Map.get(node, "scheduling_eligible")
      Map.has_key?(node, :scheduling_eligible) -> Map.get(node, :scheduling_eligible)
      true -> true
    end
  end

  defp disconnected_grace_active?(nil, _opts), do: false

  defp disconnected_grace_active?(node, opts) do
    node_status = Keyword.get(opts, :node_status)
    wait_until = disconnected_wait_until(node, opts)

    cond do
      node_status == "disconnected" ->
        is_nil(wait_until) or not wait_due?(wait_until)

      true ->
        case fetch_node_state(node, opts) do
          {:ok, %{"status" => "disconnected"} = state} ->
            state_wait_until =
              Map.get(state, "disconnect_expires_at") ||
                Map.get(state, "wait_until") ||
                Map.get(state, "recovery_wait_until")

            is_nil(state_wait_until) or not wait_due?(state_wait_until)

          _ ->
            false
        end
    end
  end

  defp disconnected_wait_until(node, opts) do
    Keyword.get(opts, :wait_until) ||
      Keyword.get(opts, :disconnect_expires_at) ||
      case fetch_node_state(node, opts) do
        {:ok, state} ->
          Map.get(state, "disconnect_expires_at") ||
            Map.get(state, "wait_until") ||
            Map.get(state, "recovery_wait_until")

        _ ->
          nil
      end
  end

  defp fetch_node_state(node, opts) do
    store = redis_store(opts)

    cond do
      function_exported?(store, :fetch_node_state, 1) ->
        store.fetch_node_state(node_name(node))

      Keyword.has_key?(opts, :redis_store) ->
        {:error, :node_state_unavailable}

      true ->
        MirrorNeuron.Cluster.NodeState.fetch(node)
    end
  rescue
    _ -> {:error, :node_state_unavailable}
  catch
    _kind, _reason -> {:error, :node_state_unavailable}
  end

  defp start_job_runner(job_id, bundle, job, scheduler_plan, opts) do
    if Keyword.get(opts, :trigger) == "node_drain" do
      wait_for_existing_runner_stopped(job_id, opts)
    end

    runner =
      Keyword.get(opts, :start_job_runner, fn start_job_id, start_bundle, start_opts ->
        spec = {JobRunner, {start_job_id, start_bundle.manifest, start_opts}}

        case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

    runner_opts =
      [
        job_bundle: bundle,
        bundle_ref: job["manifest_ref"],
        requested_recovery_policy: job["requested_recovery_policy"],
        recovery_policy: job["recovery_policy"],
        reliability: job["reliability"],
        scheduler_plan: scheduler_plan
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    runner.(job_id, bundle, runner_opts)
  end

  defp wait_for_existing_runner_stopped(job_id, opts) do
    timeout_ms = Keyword.get(opts, :existing_runner_stop_timeout_ms, 12_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_existing_runner_stopped(job_id, deadline)
  end

  defp do_wait_for_existing_runner_stopped(job_id, deadline) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
      [] ->
        :ok

      _entries ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(100)
          do_wait_for_existing_runner_stopped(job_id, deadline)
        end
    end
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp load_recovery_bundle(job, opts) do
    case Keyword.get(opts, :bundle_loader) do
      loader when is_function(loader, 1) -> loader.(job)
      _ -> load_durable_bundle(job)
    end
  end

  defp load_durable_bundle(job) do
    manifest_ref = job["manifest_ref"] || %{}
    storage = manifest_ref["bundle_storage"] || manifest_ref[:bundle_storage]
    fingerprint = manifest_ref["bundle_fingerprint"] || manifest_ref[:bundle_fingerprint]

    cond do
      storage == "redis" and is_binary(fingerprint) and fingerprint != "" ->
        Archive.load(fingerprint)

      true ->
        {:error, :missing_durable_bundle_reference}
    end
  end

  defp release_job_lease(job_id, job, opts) do
    owner = lease_owner(job)
    epoch = job["lease_epoch"] || get_in(job, ["lease", "epoch"])
    store = redis_store(opts)

    cond do
      is_binary(owner) and not is_nil(epoch) and
          function_exported?(store, :release_fenced_lease, 3) ->
        _ = store.release_fenced_lease("job:#{job_id}", owner, epoch)
        :ok

      is_binary(owner) and function_exported?(store, :release_lease, 2) ->
        _ = store.release_lease("job:#{job_id}", owner)
        :ok

      true ->
        :ok
    end
  end

  defp coordinator_pid(job_id, opts) do
    case Keyword.get(opts, :lookup_coordinator) do
      lookup when is_function(lookup, 1) ->
        lookup.(job_id)

      _ ->
        case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
          [{pid, _meta}] when is_pid(pid) -> {:ok, pid}
          _ -> :not_found
        end
    end
  end

  defp ensure_reschedule_policy_allows(job, agent_ids, opts) do
    if Keyword.get(opts, :skip_reschedule_policy, false) do
      :ok
    else
      agent_ids = normalize_policy_agent_ids(agent_ids)

      Enum.reduce_while(agent_ids, :ok, fn agent_id, :ok ->
        policy = LifecyclePolicy.reschedule_policy_from_job(job, agent_id)
        history = policy_history(job, agent_id, "reschedule")

        case LifecyclePolicy.attempt_decision(policy, history) do
          {:allowed, _decision} ->
            {:cont, :ok}

          {:exhausted, exhaustion} ->
            {:halt,
             {:policy_blocked,
              "reschedule policy blocked #{agent_id}: #{Map.get(exhaustion, "reason")}"}}
        end
      end)
    end
  end

  defp record_reschedule_policy_attempt(job, agent_ids, reason, opts) do
    if dry_run?(opts) or Keyword.get(opts, :skip_reschedule_policy_record, false) do
      :ok
    else
      agent_ids = normalize_policy_agent_ids(agent_ids)

      next_policy_state =
        Enum.reduce(agent_ids, Map.get(job, "policy_state", %{"agents" => %{}}), fn agent_id,
                                                                                    policy_state ->
          policy = LifecyclePolicy.reschedule_policy_from_job(job, agent_id)
          history = policy_history(%{"policy_state" => policy_state}, agent_id, "reschedule")

          history =
            LifecyclePolicy.append_history(
              history,
              "reschedule",
              reason || "cluster reconciliation"
            )

          put_policy_agent_fields(policy_state, agent_id, %{
            "reschedule_history" => history,
            "reschedule_attempts" => LifecyclePolicy.active_attempt_count(policy, history),
            "last_reason" => reason,
            "next_action" => "reschedule",
            "next_eligible_at" => Runtime.timestamp(),
            "updated_at" => Runtime.timestamp()
          })
        end)

      defaults = job_defaults(job, Runtime.timestamp())

      case redis_store(opts).persist_terminal_job(
             job["job_id"],
             %{"policy_state" => next_policy_state},
             defaults
           ) do
        {:ok, _job} ->
          :ok

        {:error, persist_reason} ->
          Logger.warning(
            "failed to persist reschedule policy attempt for #{job["job_id"]}: #{inspect(persist_reason)}"
          )

          :ok
      end
    end
  end

  defp normalize_policy_agent_ids([]), do: ["__job__"]

  defp normalize_policy_agent_ids(agent_ids) do
    agent_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["__job__"]
      ids -> Enum.uniq(ids)
    end
  end

  defp policy_history(job, agent_id, kind) do
    get_in(job, ["policy_state", "agents", agent_id, "#{kind}_history"]) || []
  end

  defp put_policy_agent_fields(policy_state, agent_id, fields) do
    policy_state = Map.put_new(policy_state || %{}, "agents", %{})
    agents = Map.get(policy_state, "agents", %{})
    current = Map.get(agents, agent_id, %{})

    policy_state
    |> Map.put("agents", Map.put(agents, agent_id, Map.merge(current, fields)))
    |> Map.put("updated_at", Runtime.timestamp())
  end

  defp whole_job_policy_agents(job) do
    job
    |> get_in(["scheduler", "placements"])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "agent_id"))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["__job__"]
      ids -> ids
    end
  end

  defp current_target_nodes(job, agent_ids) do
    agent_ids
    |> Enum.map(&Scheduler.target_node(Map.get(job, "scheduler", %{}), &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp filter_only_job_ids(jobs, nil), do: jobs

  defp filter_only_job_ids(jobs, job_ids) do
    allowed =
      job_ids
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.filter(jobs, &(Map.get(&1, "job_id") in allowed))
  end

  defp affected_by_node?(job, node) do
    lease_owner(job) == node or
      Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), node) != []
  end

  defp safe_to_sweep?(job) do
    case DateTime.from_iso8601(job["updated_at"] || job["submitted_at"] || "") do
      {:ok, dt, _offset} ->
        DateTime.diff(DateTime.utc_now(), dt, :millisecond) > 15_000

      _ ->
        true
    end
  end

  defp job_defaults(job, now) do
    %{
      "graph_id" => job["graph_id"] || "unknown",
      "job_name" => job["job_name"] || job["graph_id"] || "unknown",
      "root_agent_ids" => job["root_agent_ids"] || [],
      "placement_policy" => job["placement_policy"] || "local",
      "requested_recovery_policy" => job["requested_recovery_policy"] || "auto",
      "recovery_policy" => job["recovery_policy"] || "local_restart",
      "reliability" => job["reliability"] || %{},
      "restart_policy" => job["restart_policy"],
      "reschedule_policy" => job["reschedule_policy"],
      "policy_state" => job["policy_state"] || %{"agents" => %{}},
      "manifest" => job["manifest"],
      "manifest_ref" => job["manifest_ref"] || %{},
      "submitted_at" => job["submitted_at"] || now
    }
  end

  defp cluster_recoverable?(job) do
    Map.get(job, "recovery_policy", "local_restart") == "cluster_recover"
  end

  defp node_scoped_job?(job), do: job_type(job) in ["system", "sysbatch"]

  defp job_type(job) do
    job["job_type"] || get_in(job, ["scheduler", "job_type"]) || "batch"
  end

  defp lease_owner(job), do: job["lease_owner"] || get_in(job, ["lease", "owner_id"])

  defp publish(job_id, opts, event) do
    _ = event_bus(opts).publish(job_id, event)
    :ok
  end

  defp skipped(job, reason), do: %{job_id: job["job_id"], action: :skipped, reason: reason}
  defp failed(job, reason), do: %{job_id: job["job_id"], action: :failed, reason: reason}

  defp blocked(job, reason, extra),
    do: Map.merge(%{job_id: job["job_id"], action: :blocked, reason: reason}, extra)

  defp paused(job, reason, extra),
    do: Map.merge(%{job_id: job["job_id"], action: :paused_for_review, reason: reason}, extra)

  defp recovered(job, reason, extra),
    do: Map.merge(%{job_id: job["job_id"], action: :recovered, reason: reason}, extra)

  defp record(acc, result) do
    acc
    |> Map.update!(:checked, &(&1 + 1))
    |> Map.update!(:jobs, &[result | &1])
    |> bump(result.action)
  end

  defp bump(acc, :recovered), do: Map.update!(acc, :recovered, &(&1 + 1))
  defp bump(acc, :paused_for_review), do: Map.update!(acc, :paused, &(&1 + 1))
  defp bump(acc, :blocked), do: Map.update!(acc, :blocked, &(&1 + 1))
  defp bump(acc, :failed), do: Map.update!(acc, :failed, &(&1 + 1))
  defp bump(acc, _action), do: Map.update!(acc, :skipped, &(&1 + 1))

  defp finalize_result(result), do: Map.update!(result, :jobs, &Enum.reverse/1)

  defp redis_store(opts), do: Keyword.get(opts, :redis_store, RedisStore)
  defp event_bus(opts), do: Keyword.get(opts, :event_bus, EventBus)
  defp dry_run?(opts), do: Keyword.get(opts, :dry_run, false)

  defp scheduler_opts(opts, overrides),
    do: Keyword.merge(Keyword.get(opts, :scheduler_opts, []), overrides)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp iso_after(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(delay_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp config_positive_integer(env_name, default) do
    case System.get_env(env_name) do
      nil -> default
      "" -> default
      value -> integer_value(value, default)
    end
  end

  defp integer_value(value, _default) when is_integer(value) and value >= 0, do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp stringify_result(result) when is_map(result) do
    Enum.into(result, %{}, fn {key, value} -> {to_string(key), stringify_result(value)} end)
  end

  defp stringify_result(values) when is_list(values), do: Enum.map(values, &stringify_result/1)
  defp stringify_result(value), do: value

  defp node_name(node) when is_atom(node), do: Atom.to_string(node)
  defp node_name(node) when is_binary(node), do: node
  defp node_name(node), do: to_string(node)
end
