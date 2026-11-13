defmodule MirrorNeuron.Runtime.JobCoordinator.Recovery do
  @moduledoc "Applies restart and reschedule decisions to failed or missing workers."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Pause
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Targets
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.JobCoordinator.Values
  alias MirrorNeuron.Runtime.JobCoordinator.Workers
  alias MirrorNeuron.Runtime.JobCoordinator.Workflow
  alias MirrorNeuron.Runtime.LifecyclePolicy

  def handle_runtime_agent_failed(state, agent_id, reason) do
    if service_auxiliary_retry_safe?(state, agent_id, reason) do
      EventBus.publish(state.job_id, %{
        type: :service_agent_failed,
        agent_id: agent_id,
        reason: Values.stringify(reason),
        timestamp: Runtime.timestamp()
      })

      # AgentWorker already returned the failed delivery to its durable retry
      # queue. Keep that healthy owner alive so it can reclaim the command after
      # the short delivery backoff; replacing it would strand the lease until the
      # stale-delivery timeout and still must not replay the workflow.
      {:noreply, state}
    else
      restart_clean_attempt(state, {:agent_failed, agent_id, reason})
    end
  end

  def service_auxiliary_retry_safe?(state, agent_id, reason) do
    node = Map.get(state.nodes_by_id, agent_id)
    config = if is_map(node), do: Map.get(node, :config, %{}), else: %{}

    Topology.job_type(state) == "service" and
      not Workflow.workflow_agent?(state, agent_id) and
      is_map(reason) and
      is_map(config) and
      Map.get(config, "safe_to_retry") == true
  end

  def restart_agents_now(state, agent_ids, reason) do
    agent_ids = Topology.normalize_agent_ids(agent_ids, state)
    Processes.terminate_agent_workers(state, agent_ids)

    with :ok <- Processes.wait_for_agents_stopped(state, 5_000, agent_ids),
         {:ok, next_state} <- Workers.recover_agents(state, agent_ids) do
      Snapshots.persist_job(next_state)

      EventBus.publish(state.job_id, %{
        type: :agents_restarted,
        affected_agents: agent_ids,
        reason: reason,
        timestamp: Runtime.timestamp()
      })

      {:ok, next_state}
    else
      {:error, failed_reason, failed_state} -> {:error, failed_reason, failed_state}
      {:error, failed_reason} -> {:error, failed_reason, state}
    end
  end

  def schedule_missing_agents(state) do
    Enum.reduce_while(state.agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      cond do
        Targets.agent_completed?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        Processes.agent_ready?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        Targets.ignorable_missing_agent?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        Workflow.workflow_agent_active?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        Workflow.workflow_agent_inactive?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        Policy.pending_policy_action?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        true ->
          {:halt,
           {:error, {:agent_missing, agent_id, "agent missing during health check"}, acc_state}}
      end
    end)
  end

  def restart_clean_attempt(state, reason) do
    restart_reason = inspect(reason)
    next_state = %{state | restart_reason: restart_reason}

    _ =
      RedisStore.persist_terminal_job(state.job_id, %{
        "status" => "running",
        "restart_reason" => restart_reason,
        "recovery_mode" => "clean_restart",
        "lease_epoch" => get_in(Keyword.get(state.opts, :job_lease, %{}), ["epoch"])
      })

    EventBus.publish(state.job_id, %{
      type: :job_clean_restart_scheduled,
      mode: "clean_restart",
      attempt: state.attempt,
      reason: restart_reason,
      timestamp: Runtime.timestamp()
    })

    {:stop, {:clean_restart, reason}, next_state}
  end

  def schedule_agent_restarts(state, agent_ids, reason) do
    agent_ids = Topology.normalize_agent_ids(agent_ids, state)

    Enum.reduce_while(agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      policy = Policy.restart_policy(acc_state, agent_id)
      history = Policy.policy_history(acc_state, agent_id, "restart")

      case LifecyclePolicy.attempt_decision(policy, history) do
        {:allowed, decision} ->
          next_state = schedule_restart_attempt(acc_state, agent_id, reason, policy, decision)
          {:cont, {:ok, next_state}}

        {:exhausted, exhaustion} ->
          case handle_restart_exhausted(acc_state, agent_id, reason, policy, exhaustion) do
            {:ok, next_state} -> {:cont, {:ok, next_state}}
            {:error, failed_reason, next_state} -> {:halt, {:error, failed_reason, next_state}}
          end
      end
    end)
  end

  defp schedule_restart_attempt(state, agent_id, reason, policy, decision) do
    delay_ms = Map.get(decision, "delay_ms", 0)
    next_eligible_at = LifecyclePolicy.iso_after(delay_ms)

    history =
      LifecyclePolicy.append_history(
        Policy.policy_history(state, agent_id, "restart"),
        "restart",
        reason
      )

    next_state =
      state
      |> Policy.put_policy_history(agent_id, "restart", history)
      |> Policy.put_policy_agent_fields(agent_id, %{
        "last_reason" => Values.stringify(reason),
        "next_action" => "restart",
        "next_eligible_at" => next_eligible_at,
        "exhausted_reason" => nil,
        "restart_attempts" => LifecyclePolicy.active_attempt_count(policy, history)
      })
      |> Policy.schedule_policy_timer(
        {:restart, agent_id},
        {:policy_restart, agent_id, reason},
        delay_ms
      )

    Snapshots.persist_job(next_state)

    EventBus.publish(state.job_id, %{
      type: :agent_restart_scheduled,
      agent_id: agent_id,
      reason: Values.stringify(reason),
      job_type: Topology.job_type(state),
      attempt: decision["attempt"],
      delay_ms: delay_ms,
      next_eligible_at: next_eligible_at,
      restart_policy: policy,
      timestamp: Runtime.timestamp()
    })

    next_state
  end

  defp handle_restart_exhausted(
         state,
         agent_id,
         reason,
         %{"mode" => "delay"} = policy,
         exhaustion
       ) do
    wait_ms = Map.get(exhaustion, "wait_ms") || 0
    wait_until = Map.get(exhaustion, "wait_until") || LifecyclePolicy.iso_after(wait_ms)

    next_state =
      state
      |> Policy.put_policy_agent_fields(agent_id, %{
        "last_reason" => Values.stringify(reason),
        "next_action" => "restart",
        "next_eligible_at" => wait_until,
        "exhausted_reason" => exhaustion["reason"],
        "restart_attempts" =>
          LifecyclePolicy.active_attempt_count(
            policy,
            Policy.policy_history(state, agent_id, "restart")
          )
      })
      |> Policy.schedule_policy_timer(
        {:restart, agent_id},
        {:policy_restart, agent_id, reason},
        wait_ms
      )

    Snapshots.persist_job(next_state)

    EventBus.publish(state.job_id, %{
      type: :agent_restart_deferred,
      agent_id: agent_id,
      reason: Values.stringify(reason),
      exhausted_reason: exhaustion["reason"],
      retry_at: wait_until,
      delay_ms: wait_ms,
      timestamp: Runtime.timestamp()
    })

    {:ok, next_state}
  end

  defp handle_restart_exhausted(state, agent_id, reason, _policy, exhaustion) do
    effective_policy = Policy.effective_recovery_policy(state)

    cond do
      effective_policy == "manual_recover" ->
        {:ok,
         Pause.pause_for_policy_review(state, agent_id, "manual recovery policy requires review")}

      effective_policy == "cluster_recover" ->
        schedule_agent_reschedule(state, agent_id, reason, exhaustion)

      Topology.job_type(state) in ["service", "system"] ->
        {:ok,
         Pause.pause_for_policy_review(
           state,
           agent_id,
           "restart attempts exhausted and cluster recovery is not active"
         )}

      true ->
        {:error, "agent #{agent_id} restart attempts exhausted: #{exhaustion["reason"]}", state}
    end
  end

  defp schedule_agent_reschedule(state, agent_id, reason, restart_exhaustion) do
    policy = Policy.reschedule_policy(state, agent_id)
    history = Policy.policy_history(state, agent_id, "reschedule")

    case LifecyclePolicy.attempt_decision(policy, history) do
      {:allowed, decision} ->
        delay_ms = Map.get(decision, "delay_ms", 0)
        next_eligible_at = LifecyclePolicy.iso_after(delay_ms)

        history =
          LifecyclePolicy.append_history(
            history,
            "reschedule",
            "#{Values.stringify(reason)} after restart exhaustion"
          )

        next_state =
          state
          |> Policy.put_policy_history(agent_id, "reschedule", history)
          |> Policy.put_policy_agent_fields(agent_id, %{
            "last_reason" => Values.stringify(reason),
            "next_action" => "reschedule",
            "next_eligible_at" => next_eligible_at,
            "exhausted_reason" => restart_exhaustion["reason"],
            "reschedule_attempts" => LifecyclePolicy.active_attempt_count(policy, history)
          })
          |> Policy.schedule_policy_timer(
            {:reschedule, agent_id},
            {:policy_reschedule, [agent_id], Values.stringify(reason)},
            delay_ms
          )

        Snapshots.persist_job(next_state)

        EventBus.publish(state.job_id, %{
          type: :agent_reschedule_scheduled,
          agent_id: agent_id,
          reason: Values.stringify(reason),
          restart_exhausted_reason: restart_exhaustion["reason"],
          delay_ms: delay_ms,
          next_eligible_at: next_eligible_at,
          reschedule_policy: policy,
          timestamp: Runtime.timestamp()
        })

        {:ok, next_state}

      {:exhausted, reschedule_exhaustion} ->
        reason =
          "agent #{agent_id} restart exhausted and reschedule unavailable: " <>
            reschedule_exhaustion["reason"]

        if Topology.job_type(state) in ["service", "system"] do
          {:ok, Pause.pause_for_policy_review(state, agent_id, reason)}
        else
          {:error, reason, state}
        end
    end
  end
end
