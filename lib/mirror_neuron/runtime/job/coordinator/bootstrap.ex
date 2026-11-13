defmodule MirrorNeuron.Runtime.JobCoordinator.Bootstrap do
  @moduledoc "Builds coordinator state and starts a run after staged inputs are ready."

  alias MirrorNeuron.Artifacts.SubmissionReadiness
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Context
  alias MirrorNeuron.Runtime.JobCoordinator.Finalization
  alias MirrorNeuron.Runtime.JobCoordinator.Health
  alias MirrorNeuron.Runtime.JobCoordinator.Messages
  alias MirrorNeuron.Runtime.JobCoordinator.Pause
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.Services
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.JobCoordinator.Values
  alias MirrorNeuron.Runtime.JobCoordinator.Workers
  alias MirrorNeuron.Runtime.JobCoordinator.Workflow
  alias MirrorNeuron.Runtime.WorkflowLedger

  @default_health_check_interval_ms 2_000

  def init({job_id, manifest, opts}) do
    bundle = Keyword.get(opts, :job_bundle)

    existing_job =
      case RedisStore.fetch_job(job_id) do
        {:ok, job_map} when is_map(job_map) -> job_map
        _ -> nil
      end

    status = "pending"
    submitted_at = if existing_job, do: existing_job["submitted_at"], else: Runtime.timestamp()
    scheduler_plan = Topology.scheduler_plan_from(manifest, opts)
    runtime_topology = Topology.build_runtime_topology(manifest, scheduler_plan)

    state = %{
      job_id: job_id,
      delivery_version: Map.get(existing_job || %{}, "delivery_version", 2),
      clock_session: Values.unique_id(),
      manifest: manifest,
      bundle: bundle,
      opts: opts,
      status: status,
      result: nil,
      pause_cleanup_task: nil,
      pause_cleanup_status: nil,
      result_ref: nil,
      workflow_state_ref: nil,
      submitted_at: submitted_at,
      agent_ids: runtime_topology.agent_ids,
      runtime_nodes: runtime_topology.nodes,
      runtime_edges: runtime_topology.edges,
      runtime_entrypoints: runtime_topology.entrypoints,
      source_agent_ids: runtime_topology.source_agent_ids,
      system_targets: runtime_topology.system_targets,
      agents_by_system_target: runtime_topology.agents_by_system_target,
      nodes_by_id: Map.new(runtime_topology.nodes, &{&1.node_id, &1}),
      outbound_edges_by_node: Enum.group_by(runtime_topology.edges, & &1.from_node),
      inbound_edges_by_node: Enum.group_by(runtime_topology.edges, & &1.to_node),
      downstream_by_node: Topology.build_downstream_index(runtime_topology.edges),
      completed_agents: MapSet.new(),
      completed_system_targets: MapSet.new(),
      pressure: %{},
      policy_state: %{"agents" => %{}},
      workflow_state:
        WorkflowLedger.new(
          manifest,
          runtime_topology.nodes,
          if(Keyword.has_key?(opts, :checkpoint_retry), do: existing_job, else: nil),
          job_id
        ),
      pending_policy_timers: %{},
      recovery_tasks: %{},
      health_check_timer_ref: nil,
      health_check_token: nil,
      coordinator_delivery_consumer:
        Delivery.consumer_id(job_id, Delivery.coordinator_agent_id()),
      coordinator_delivery_group_ready?: false,
      coordinator_delivery_reclaim?: true,
      coordinator_delivery_next_reclaim_at_ms: 0,
      coordinator_delivery_timer_ref: nil,
      coordinator_delivery_token: nil,
      deployment_context: Topology.deployment_context_from(opts, existing_job),
      health_check_interval_ms:
        Application.get_env(
          :mirror_neuron,
          :job_health_check_interval_ms,
          @default_health_check_interval_ms
        ),
      reliability: Policy.reliability_from(opts, existing_job),
      recovery_fields: Snapshots.recovery_fields_from(existing_job),
      pending_workflow_completion: nil,
      attempt: Keyword.get(opts, :attempt, Map.get(existing_job || %{}, "attempt", 1)),
      attempt_started_at:
        Keyword.get(
          opts,
          :attempt_started_at,
          Map.get(existing_job || %{}, "attempt_started_at", Runtime.timestamp())
        ),
      restart_reason:
        Keyword.get(
          opts,
          :restart_reason,
          Map.get(existing_job || %{}, "restart_reason", "initial_start")
        ),
      attempt_history: Map.get(existing_job || %{}, "attempt_history", []),
      retry_receipts: Map.get(existing_job || %{}, "retry_receipts", %{}),
      workflow_budgets:
        if(Keyword.has_key?(opts, :checkpoint_retry),
          do: Map.get(existing_job || %{}, "workflow_budgets", %{}),
          else: %{}
        ),
      restart_budget: Map.get(existing_job || %{}, "restart_budget"),
      attempt_not_before: Map.get(existing_job || %{}, "attempt_not_before"),
      submission_storage: %{
        started_at_ms: System.monotonic_time(:millisecond),
        timer_token: nil,
        last_wait_event_at_ms: nil,
        waiting?: false
      }
    }

    state = Context.cache_definition(state)

    case MirrorNeuron.Runtime.WorkflowBudget.register_owner(
           Keyword.get(opts, :stable_job_id) || job_id,
           WorkflowLedger.run_id(state.workflow_state),
           manifest.policies
         ) do
      :ok -> {:ok, state, {:continue, :bootstrap}}
      {:error, reason} -> {:stop, reason}
    end
  end

  def handle_continue(:recover, state) do
    handle_continue(:bootstrap, state)
  end

  def handle_continue(:bootstrap, state) do
    EventBus.publish(state.job_id, %{type: :job_validated, timestamp: Runtime.timestamp()})

    EventBus.publish(state.job_id, %{
      type: :job_scheduled,
      node: to_string(Node.self()),
      timestamp: Runtime.timestamp()
    })

    case Workers.start_agents(state) do
      {:ok, boot_state} ->
        continue_bootstrap_after_storage_check(boot_state)

      {:error, {:execution_profile_unavailable, profile, agent_id}, failed_state} ->
        paused_state =
          Pause.pause_for_profile_review(
            failed_state,
            profile,
            agent_id,
            "execution profile #{profile} has no eligible runtime nodes"
          )

        {:stop, :normal, paused_state}

      {:error, reason, failed_state} ->
        fail_bootstrap(failed_state, reason)
    end
  end

  def continue_bootstrap_after_storage_check(state) do
    case submission_storage_status(state) do
      {:ready, ready_state} ->
        complete_ready_bootstrap(ready_state)

      {:waiting, waiting_state} ->
        Snapshots.persist_job(waiting_state)
        {:noreply, schedule_submission_storage_check(waiting_state)}

      {:error, reason, failed_state} ->
        fail_bootstrap(failed_state, reason)
    end
  end

  defp complete_ready_bootstrap(state) do
    case complete_bootstrap(state) do
      {:ok, next_state, workflow_events} ->
        Snapshots.persist_durable_job_snapshot(next_state, Snapshots.job_snapshot(next_state))

        EventBus.publish(state.job_id, %{
          type: :job_running,
          mode: "clean_restart",
          attempt: next_state.attempt,
          attempt_started_at: next_state.attempt_started_at,
          restart_reason: next_state.restart_reason,
          timestamp: Runtime.timestamp()
        })

        Workflow.publish_workflow_events(next_state, workflow_events)
        {:noreply, Health.schedule_runtime_timers(next_state)}

      {:error, reason, failed_state} ->
        fail_bootstrap(failed_state, reason)
    end
  end

  defp fail_bootstrap(state, reason) do
    failed_state =
      Finalization.finalize_job(state, "failed", %{error: reason}, :job_failed, %{reason: reason})

    {:stop, {:shutdown, reason}, failed_state}
  end

  defp complete_bootstrap(state) do
    with :ok <- Processes.wait_for_agents_ready(state),
         :ok <- Services.register_runtime_services(state) do
      {ledger, events} = WorkflowLedger.job_running(state.workflow_state)
      running = %{state | status: "running", workflow_state: ledger}

      if Keyword.has_key?(state.opts, :checkpoint_retry) do
        Snapshots.persist_durable_job_snapshot(running, Snapshots.job_snapshot(running))
        {ledger, retry_events, actions} = WorkflowLedger.reconcile(running.workflow_state)
        restored = %{running | workflow_state: ledger}

        case Workflow.apply_workflow_actions(restored, actions) do
          {:ok, next} -> {:ok, next, events ++ retry_events}
          {:fail_job, _, reason, failed} -> {:error, reason, failed}
        end
      else
        case Messages.seed_initial_entrypoints(running) do
          :ok -> {:ok, running, events}
          {:error, reason} -> {:error, reason, running}
        end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A submission readiness marker is present only for SDK-staged host inputs.
  # Workers are prepared first, but no generated source receives its initial
  # message until the selected owner has verified every staged file locally.

  defp submission_storage_status(state),
    do: MirrorNeuron.Runtime.SubmissionPreparation.status(state)

  defp schedule_submission_storage_check(state) do
    storage = Map.get(state, :submission_storage, %{})
    token = make_ref()

    Process.send_after(
      self(),
      {:submission_storage_check, token},
      SubmissionReadiness.poll_interval_ms()
    )

    %{state | submission_storage: Map.put(storage, :timer_token, token)}
  end

  def clear_submission_storage_check(state) do
    storage = Map.get(state, :submission_storage, %{})
    %{state | submission_storage: Map.put(storage, :timer_token, nil)}
  end
end
