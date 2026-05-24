defmodule MirrorNeuron.Cluster.Reconciler do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{EventBus, JobRunner, RecoverySafety}
  alias MirrorNeuron.Scheduler

  @active_statuses ["pending", "running", "paused"]
  @empty_result %{checked: 0, recovered: 0, paused: 0, skipped: 0, failed: 0, jobs: []}

  def reconcile_node(node, opts \\ []) do
    node_name = node_name(node)

    with {:ok, jobs} <- redis_store(opts).list_jobs() do
      result =
        jobs
        |> Enum.filter(&(Map.get(&1, "status") in @active_statuses))
        |> Enum.reduce(@empty_result, fn job, acc ->
          if affected_by_node?(job, node_name) do
            record(acc, reconcile_affected_job(job, node_name, opts))
          else
            record(acc, skipped(job, "job is not affected by #{node_name}"))
          end
        end)

      {:ok, finalize_result(result)}
    end
  end

  def sweep_orphaned_jobs(owner_node \\ nil, opts \\ []) do
    owner_node = if is_nil(owner_node), do: nil, else: node_name(owner_node)

    with {:ok, jobs} <- redis_store(opts).list_jobs() do
      result =
        jobs
        |> Enum.filter(&(Map.get(&1, "status") in @active_statuses))
        |> Enum.filter(fn job -> is_nil(owner_node) or lease_owner(job) == owner_node end)
        |> Enum.reduce(@empty_result, fn job, acc ->
          record(acc, reconcile_orphaned_job(job, opts))
        end)

      {:ok, finalize_result(result)}
    end
  end

  defp reconcile_affected_job(job, failed_node, opts) do
    affected_agents = Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), failed_node)
    owner_match? = lease_owner(job) == failed_node
    reason = Keyword.get(opts, :reason, "node #{failed_node} is unavailable")

    cond do
      not cluster_recoverable?(job) ->
        pause_for_review(job, reason, failed_node, affected_agents, opts)

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
         {:ok, partial_plan} <-
           Scheduler.plan(
             bundle.manifest,
             scheduler_opts(opts,
               exclude_nodes: [failed_node],
               ignore_job_ids: [job_id],
               only_agent_ids: affected_agents
             )
           ) do
      scheduler_plan = Scheduler.merge_plan(Map.get(job, "scheduler", %{}), partial_plan)

      if dry_run?(opts) do
        recovered(job, "would reschedule agents", %{
          mode: "agents",
          affected_agents: affected_agents,
          scheduler: scheduler_plan
        })
      else
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
         {:ok, scheduler_plan} <-
           Scheduler.plan(
             bundle.manifest,
             scheduler_opts(opts,
               exclude_nodes: List.wrap(failed_node),
               ignore_job_ids: [job_id]
             )
           ) do
      if dry_run?(opts) do
        recovered(job, "would restart job", %{mode: "job", scheduler: scheduler_plan})
      else
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

  defp wait_for_node_scoped_recovery(job, failed_node, affected_agents, reason, opts) do
    wait_reason =
      "#{job_type(job)} allocations are scoped to their original runtime node; " <>
        "waiting for #{failed_node} to recover instead of relocating them"

    unless dry_run?(opts) do
      mark_recovery(job, "waiting_for_node", wait_reason, failed_node, affected_agents, opts)

      publish(job["job_id"], opts, %{
        type: :job_node_scoped_recovery_waiting,
        reason: reason,
        detail: wait_reason,
        failed_node: failed_node,
        affected_agents: affected_agents,
        timestamp: Runtime.timestamp()
      })
    end

    skipped(job, wait_reason)
  end

  defp mark_recovery(job, status, reason, failed_node, affected_agents, opts, mark_opts \\ []) do
    now = Runtime.timestamp()
    requires_review? = Keyword.get(mark_opts, :requires_review?, false)

    recovery = %{
      "status" => status,
      "reason" => reason,
      "requires_review" => requires_review?,
      "can_resume" => requires_review?,
      "failed_node" => failed_node,
      "affected_agents" => affected_agents,
      "updated_at" => now
    }

    updates =
      %{
        "recovery" => recovery,
        "recovery_status" => status,
        "recovery_reason" => reason,
        "recovery_requires_review" => requires_review?
      }
      |> maybe_put("status", Keyword.get(mark_opts, :status))

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

  defp start_job_runner(job_id, bundle, job, scheduler_plan, opts) do
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

  defp node_name(node) when is_atom(node), do: Atom.to_string(node)
  defp node_name(node) when is_binary(node), do: node
  defp node_name(node), do: to_string(node)
end
