defmodule MirrorNeuron.Cluster.Reconciler.Status do
  @moduledoc "Records recovery outcomes and publishes matching cluster events."

  require Logger

  alias MirrorNeuron.Cluster.Reconciler.Jobs
  alias MirrorNeuron.Cluster.Reconciler.NodeAvailability
  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Cluster.Reconciler.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Cluster.Reconciler.Timing

  def pause_for_review(job, reason, failed_node, affected_agents, opts) do
    if Options.dry_run?(opts) do
      Results.paused(job, reason, %{failed_node: failed_node, affected_agents: affected_agents})
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

      Results.paused(job, reason, %{failed_node: failed_node, affected_agents: affected_agents})
    end
  end

  def block_recovery(job, reason, failed_node, affected_agents, opts, block_opts \\ []) do
    wait_until =
      Keyword.get(block_opts, :wait_until) ||
        Timing.retry_wait_until(Keyword.get(opts, :eval, %{}), opts)

    status = Keyword.get(block_opts, :status, "blocked_no_placement")

    if Options.dry_run?(opts) do
      Results.blocked(job, reason, %{
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

      Results.blocked(job, reason, %{
        failed_node: failed_node,
        affected_agents: affected_agents,
        wait_until: wait_until
      })
    end
  end

  def wait_for_disconnected_node(job, failed_node, affected_agents, reason, opts) do
    wait_until =
      NodeAvailability.disconnected_wait_until(failed_node, opts) ||
        Timing.retry_wait_until(Keyword.get(opts, :eval, %{}), opts)

    wait_reason =
      "node #{failed_node} is inside its disconnect grace window; waiting before relocating work"

    block_recovery(job, wait_reason, failed_node, affected_agents, opts,
      status: "waiting_for_node",
      wait_until: wait_until,
      reason: reason
    )
  end

  def wait_for_node_scoped_recovery(job, failed_node, affected_agents, reason, opts) do
    wait_reason =
      "#{Jobs.job_type(job)} allocations are scoped to their original runtime node; " <>
        "waiting for #{failed_node} to recover instead of relocating them"

    unless Options.dry_run?(opts) do
      wait_until = Timing.retry_wait_until(Keyword.get(opts, :eval, %{}), opts)

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

    Results.blocked(job, wait_reason, %{
      failed_node: failed_node,
      affected_agents: affected_agents,
      wait_until: Timing.retry_wait_until(Keyword.get(opts, :eval, %{}), opts)
    })
  end

  def mark_recovery(job, status, reason, failed_node, affected_agents, opts, mark_opts \\ []) do
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

    defaults = Jobs.job_defaults(job, now)

    case Options.redis_store(opts).persist_terminal_job(job["job_id"], updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist reconciliation status for #{job["job_id"]}: #{inspect(persist_reason)}"
        )
    end
  end

  def publish(job_id, opts, event) do
    _ = Options.event_bus(opts).publish(job_id, event)
    :ok
  end

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
