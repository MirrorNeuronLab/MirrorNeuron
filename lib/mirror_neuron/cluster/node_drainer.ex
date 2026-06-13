defmodule MirrorNeuron.Cluster.NodeDrainer do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Cluster.{NodeState, Reconciler}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Scheduler

  @active_job_statuses ["pending", "running", "paused"]
  @system_job_types ["system", "sysbatch"]
  @completion_statuses ["complete", "completed", "succeeded", "failed", "cancelled", "stopped"]
  @default_deadline_ms 1_800_000

  def drain_node(node, opts \\ []) do
    node_name = node_name(node)
    dry_run? = option(opts, :dry_run, false)
    continue? = option(opts, :continue, false)
    existing = node_state(node_name, opts)
    existing_drain = Map.get(existing, "drain", %{})
    now = Runtime.timestamp()

    context = %{
      node: node_name,
      dry_run?: dry_run?,
      continue?: continue?,
      reason:
        option(opts, :reason) ||
          Map.get(existing_drain, "reason") ||
          "operator requested node drain",
      ignore_system_jobs:
        option(
          opts,
          :ignore_system_jobs,
          Map.get(existing_drain, "ignore_system_jobs", true)
        ) != false,
      deadline_ms: option(opts, :deadline_ms, @default_deadline_ms),
      started_at: if(continue?, do: Map.get(existing_drain, "started_at") || now, else: now),
      deadline_at:
        if continue? and Map.get(existing_drain, "deadline_at") do
          Map.get(existing_drain, "deadline_at")
        else
          iso_after(option(opts, :deadline_ms, @default_deadline_ms))
        end,
      opts: opts
    }

    unless dry_run? do
      {:ok, _state} = mark_draining(context)
      publish_node_event(:node_drain_started, context, %{})
    end

    with {:ok, jobs} <- list_jobs(opts) do
      result =
        jobs
        |> Enum.filter(&active_job?/1)
        |> Enum.filter(&job_on_node?(&1, node_name))
        |> Enum.reduce(empty_result(context), fn job, acc ->
          record_action(acc, process_job(job, context))
        end)
        |> maybe_complete_drain(context)

      {:ok, result}
    end
  end

  def cancel_node_drain(node, opts \\ []) do
    node_name = node_name(node)
    reason = option(opts, :reason, "operator cancelled node drain")
    mark_eligible? = option(opts, :mark_eligible, false)
    now = Runtime.timestamp()
    existing = node_state(node_name, opts)

    status = if mark_eligible?, do: "healthy", else: "maintenance"

    drain =
      existing
      |> Map.get("drain", %{})
      |> Map.merge(%{
        "status" => "cancelled",
        "reason" => reason,
        "completed_at" => now,
        "cancelled_at" => now
      })

    {:ok, state} =
      put_node_state(node_name, status, opts, %{
        "scheduling_eligible" => mark_eligible?,
        "drain" => drain
      })

    result = %{
      "node" => node_name,
      "status" => "cancelled",
      "scheduling_eligible" => mark_eligible?,
      "reason" => reason,
      "node_state" => state
    }

    publish_node_event(:node_drain_cancelled, %{node: node_name, reason: reason, opts: opts}, %{
      mark_eligible: mark_eligible?
    })

    {:ok, result}
  end

  def set_node_maintenance(node, enabled, opts \\ []) do
    node_name = node_name(node)
    enabled? = enabled in [true, "true", "TRUE", "1", 1, "yes", "on"]
    reason = option(opts, :reason, "operator changed node maintenance")
    now = Runtime.timestamp()
    existing = node_state(node_name, opts)

    {status, eligible, event_type} =
      if enabled? do
        {"maintenance", false, :node_maintenance_enabled}
      else
        {"healthy", true, :node_maintenance_disabled}
      end

    maintenance =
      %{
        "enabled" => enabled?,
        "reason" => reason,
        "updated_at" => now
      }
      |> maybe_put("disabled_at", if(enabled?, do: nil, else: now))

    {:ok, state} =
      put_node_state(node_name, status, opts, %{
        "scheduling_eligible" => eligible,
        "maintenance" => maintenance,
        "drain" => Map.get(existing, "drain")
      })

    result = %{
      "node" => node_name,
      "status" => status,
      "scheduling_eligible" => eligible,
      "maintenance" => maintenance,
      "node_state" => state
    }

    publish_node_event(event_type, %{node: node_name, reason: reason, opts: opts}, %{})
    {:ok, result}
  end

  def node_drain_status(node, opts \\ []) do
    node_name = node_name(node)
    state = node_state(node_name, opts)

    {:ok,
     %{
       "node" => node_name,
       "status" => Map.get(state, "status", "unknown"),
       "scheduling_eligible" => Map.get(state, "scheduling_eligible", true),
       "drain" => Map.get(state, "drain", %{}),
       "maintenance" => Map.get(state, "maintenance", %{}),
       "node_state" => state
     }}
  end

  def process_due_drains(opts \\ []) do
    with {:ok, states} <- list_node_states(opts) do
      states
      |> Enum.filter(&due_drain_state?/1)
      |> Enum.reduce({:ok, empty_sweep_result()}, fn state, {:ok, acc} ->
        node = Map.get(state, "node")

        case drain_node(node, Keyword.merge(opts, continue: true)) do
          {:ok, result} -> {:ok, merge_sweep_result(acc, result)}
          {:error, reason} -> {:ok, record_sweep_failure(acc, node, reason)}
        end
      end)
    end
  end

  defp mark_draining(context) do
    drain = %{
      "status" => "draining",
      "started_at" => context.started_at,
      "deadline_at" => context.deadline_at,
      "deadline_ms" => context.deadline_ms,
      "reason" => context.reason,
      "ignore_system_jobs" => context.ignore_system_jobs,
      "completed_at" => nil,
      "counters" => %{}
    }

    put_node_state(context.node, "draining", context.opts, %{
      "scheduling_eligible" => false,
      "drain" => drain
    })
  end

  defp process_job(job, context) do
    job_type = job_type(job)
    affected_agents = Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), context.node)
    owner_on_node? = lease_owner(job) == context.node

    cond do
      affected_agents == [] and not owner_on_node? ->
        action(job, "skipped", "job has no placements on #{context.node}", affected_agents)

      context.ignore_system_jobs and job_type in @system_job_types ->
        action(job, "ignored", "#{job_type} job is ignored during drain", affected_agents)

      job_type in ["batch", "sysbatch"] and not deadline_due?(context.deadline_at) ->
        action(
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

    case reconciler(context.opts).reconcile_node(context.node, reconciler_opts) do
      {:ok, %{} = result} ->
        classify_reconcile_result(job, affected_agents, result, context)

      {:error, reason} ->
        action(job, "failed", "drain migration failed: #{inspect(reason)}", affected_agents)
    end
  end

  defp classify_reconcile_result(job, affected_agents, result, context) do
    cond do
      Map.get(result, :recovered, 0) > 0 or Map.get(result, "recovered", 0) > 0 ->
        action(
          job,
          if(context.dry_run?, do: "would_migrate", else: "migrated"),
          if(context.dry_run?, do: "would migrate during drain", else: "migrated during drain"),
          affected_agents,
          %{"reconcile" => json_safe(result)}
        )

      Map.get(result, :blocked, 0) > 0 or Map.get(result, "blocked", 0) > 0 ->
        action(job, "blocked", "drain migration is blocked", affected_agents, %{
          "reconcile" => json_safe(result)
        })

      Map.get(result, :paused, 0) > 0 or Map.get(result, "paused", 0) > 0 ->
        action(job, "paused_for_review", "drain migration paused for review", affected_agents, %{
          "reconcile" => json_safe(result)
        })

      Map.get(result, :failed, 0) > 0 or Map.get(result, "failed", 0) > 0 ->
        action(job, "failed", "drain migration failed", affected_agents, %{
          "reconcile" => json_safe(result)
        })

      true ->
        action(job, "skipped", "drain reconciliation did not move this job", affected_agents, %{
          "reconcile" => json_safe(result)
        })
    end
  end

  defp maybe_complete_drain(result, context) do
    result =
      result
      |> put_in(["counters"], counters(result["actions"]))
      |> Map.put("deadline_at", context.deadline_at)
      |> Map.put("started_at", context.started_at)
      |> Map.put("reason", context.reason)

    status = drain_status(result)

    if context.dry_run? do
      Map.merge(result, %{"status" => "dry_run", "would_status" => status})
    else
      drain = %{
        "status" => status,
        "started_at" => context.started_at,
        "deadline_at" => context.deadline_at,
        "deadline_ms" => context.deadline_ms,
        "reason" => context.reason,
        "ignore_system_jobs" => context.ignore_system_jobs,
        "completed_at" => if(status == "complete", do: Runtime.timestamp(), else: nil),
        "counters" => result["counters"]
      }

      node_status = if status == "complete", do: "maintenance", else: "draining"

      {:ok, _state} =
        put_node_state(context.node, node_status, context.opts, %{
          "scheduling_eligible" => false,
          "drain" => drain
        })

      publish_drain_progress(status, context, result)

      result
      |> Map.put("status", status)
      |> Map.put("node_status", node_status)
      |> Map.put("scheduling_eligible", false)
    end
  end

  defp drain_status(result) do
    counters = result["counters"]

    cond do
      Map.get(counters, "failed", 0) > 0 -> "blocked_no_placement"
      Map.get(counters, "blocked", 0) > 0 -> "blocked_no_placement"
      Map.get(counters, "paused_for_review", 0) > 0 -> "paused_for_review"
      Map.get(counters, "waiting", 0) > 0 -> "draining"
      true -> "complete"
    end
  end

  defp publish_drain_progress("complete", context, result),
    do: publish_node_event(:node_drain_completed, context, %{"result" => result})

  defp publish_drain_progress("blocked_no_placement", context, result),
    do: publish_node_event(:node_drain_blocked, context, %{"result" => result})

  defp publish_drain_progress(_status, context, result),
    do: publish_node_event(:node_drain_progress, context, %{"result" => result})

  defp empty_result(context) do
    %{
      "node" => context.node,
      "status" => if(context.dry_run?, do: "dry_run", else: "draining"),
      "actions" => [],
      "counters" => %{}
    }
  end

  defp action(job, status, reason, affected_agents, extra \\ %{}) do
    %{
      "job_id" => job["job_id"],
      "job_type" => job_type(job),
      "status" => status,
      "reason" => reason,
      "affected_agents" => affected_agents
    }
    |> Map.merge(extra)
  end

  defp record_action(result, action) do
    Map.update!(result, "actions", &(&1 ++ [action]))
  end

  defp counters(actions) do
    Enum.reduce(actions, %{"checked" => length(actions)}, fn action, acc ->
      Map.update(acc, Map.get(action, "status", "unknown"), 1, &(&1 + 1))
    end)
  end

  defp empty_sweep_result do
    %{
      "checked" => 0,
      "completed" => 0,
      "blocked" => 0,
      "waiting" => 0,
      "failed" => 0,
      "nodes" => []
    }
  end

  defp merge_sweep_result(acc, result) do
    status = Map.get(result, "status")

    acc
    |> Map.update!("checked", &(&1 + 1))
    |> Map.update!("nodes", &(&1 ++ [result]))
    |> bump_sweep(status)
  end

  defp record_sweep_failure(acc, node, reason) do
    acc
    |> Map.update!("checked", &(&1 + 1))
    |> Map.update!("failed", &(&1 + 1))
    |> Map.update!(
      "nodes",
      &(&1 ++ [%{"node" => node, "status" => "failed", "reason" => inspect(reason)}])
    )
  end

  defp bump_sweep(acc, "complete"), do: Map.update!(acc, "completed", &(&1 + 1))
  defp bump_sweep(acc, "draining"), do: Map.update!(acc, "waiting", &(&1 + 1))
  defp bump_sweep(acc, "blocked_no_placement"), do: Map.update!(acc, "blocked", &(&1 + 1))
  defp bump_sweep(acc, "paused_for_review"), do: Map.update!(acc, "blocked", &(&1 + 1))
  defp bump_sweep(acc, _status), do: acc

  defp active_job?(job) do
    Map.get(job, "status") in @active_job_statuses and
      Map.get(job, "status") not in @completion_statuses
  end

  defp job_on_node?(job, node) do
    Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), node) != [] or
      Map.get(job, "lease_owner") == node or
      get_in(job, ["lease", "owner_id"]) == node
  end

  defp due_drain_state?(%{"status" => "draining", "drain" => %{"status" => status}})
       when status in ["draining", "blocked_no_placement"],
       do: true

  defp due_drain_state?(_state), do: false

  defp list_jobs(opts) do
    store = redis_store(opts)

    if function_exported?(store, :list_jobs, 0) do
      store.list_jobs()
    else
      {:ok, []}
    end
  end

  defp list_node_states(opts) do
    node_state = node_state_module(opts)
    store = redis_store(opts)

    cond do
      function_exported?(node_state, :list, 0) ->
        {:ok, node_state.list()}

      function_exported?(store, :list_node_states, 0) ->
        store.list_node_states()

      true ->
        {:ok, []}
    end
  end

  defp node_state(node, opts) do
    node_state = node_state_module(opts)

    cond do
      function_exported?(node_state, :fetch, 1) ->
        case node_state.fetch(node) do
          {:ok, state} when is_map(state) -> state
          _ -> %{"node" => node}
        end

      true ->
        %{"node" => node}
    end
  rescue
    _ -> %{"node" => node}
  end

  defp put_node_state(node, status, opts, updates) do
    node_state = node_state_module(opts)
    existing = node_state(node, opts)
    attrs = existing |> Map.merge(updates) |> Map.put("node", node)

    if function_exported?(node_state, :mark, 3) do
      node_state.mark(node, status, attrs)
    else
      {:ok, Map.put(attrs, "status", status)}
    end
  end

  defp publish_node_event(type, context, extra) do
    event =
      %{
        type: type,
        node: context.node,
        reason: context.reason,
        timestamp: Runtime.timestamp()
      }
      |> Map.merge(extra)

    event_bus(context.opts).publish("__cluster__", event)
  rescue
    reason ->
      Logger.debug("failed to publish node drain event #{inspect(type)}: #{inspect(reason)}")
      :ok
  catch
    _kind, reason ->
      Logger.debug("failed to publish node drain event #{inspect(type)}: #{inspect(reason)}")
      :ok
  end

  defp deadline_due?(deadline_at) do
    case DateTime.from_iso8601(to_string(deadline_at)) do
      {:ok, deadline, _offset} -> DateTime.compare(deadline, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp iso_after(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(integer_value(delay_ms, @default_deadline_ms), :millisecond)
    |> DateTime.to_iso8601()
  end

  defp job_type(job), do: job["job_type"] || get_in(job, ["scheduler", "job_type"]) || "batch"

  defp lease_owner(job), do: job["lease_owner"] || get_in(job, ["lease", "owner_id"])

  defp json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value), do: value

  defp option(opts, key, default \\ nil) do
    MirrorNeuron.SafeAccess.keyword_get(opts, key, default)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp integer_value(value, _default) when is_integer(value) and value >= 0, do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp node_state_module(opts), do: Keyword.get(opts, :node_state, NodeState)
  defp redis_store(opts), do: Keyword.get(opts, :redis_store, RedisStore)
  defp reconciler(opts), do: Keyword.get(opts, :reconciler, Reconciler)
  defp event_bus(opts), do: Keyword.get(opts, :event_bus, EventBus)

  defp node_name(node) when is_atom(node), do: Atom.to_string(node)
  defp node_name(node) when is_binary(node), do: node
  defp node_name(node), do: to_string(node)
end
