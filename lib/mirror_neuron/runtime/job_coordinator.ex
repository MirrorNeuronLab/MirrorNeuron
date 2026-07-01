defmodule MirrorNeuron.Runtime.JobCoordinator do
  use GenServer
  require Logger

  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.{ServiceRegistry, ServiceSpec}
  alias MirrorNeuron.Scheduler

  alias MirrorNeuron.Runtime.{
    AgentWorker,
    Backpressure,
    ErrorEnvelope,
    EventBus,
    LifecyclePolicy,
    Naming,
    WorkflowLedger
  }

  alias MirrorNeuron.Sandbox.{DockerJobSandbox, OpenShellJobSandbox}

  @default_health_check_interval_ms 2_000

  def start_link({job_id, manifest, opts}) do
    GenServer.start_link(__MODULE__, {job_id, manifest, opts}, name: Naming.via_job(job_id))
  end

  @impl true
  def init({job_id, manifest, opts}) do
    bundle = Keyword.get(opts, :job_bundle)

    existing_job =
      case RedisStore.fetch_job(job_id) do
        {:ok, job_map} when is_map(job_map) -> job_map
        _ -> nil
      end

    status = if existing_job, do: existing_job["status"], else: "pending"
    submitted_at = if existing_job, do: existing_job["submitted_at"], else: Runtime.timestamp()
    result = if existing_job, do: existing_job["result"], else: nil
    scheduler_plan = scheduler_plan_from(manifest, opts)
    runtime_topology = build_runtime_topology(manifest, scheduler_plan)

    state = %{
      job_id: job_id,
      manifest: manifest,
      bundle: bundle,
      opts: opts,
      status: status,
      result: result,
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
      downstream_by_node: build_downstream_index(runtime_topology.edges),
      completed_agents: completed_agents_from(existing_job),
      completed_system_targets: completed_system_targets_from(existing_job),
      pressure: %{},
      policy_state: policy_state_from(existing_job),
      workflow_state: WorkflowLedger.new(manifest, runtime_topology.nodes, existing_job),
      pending_policy_timers: %{},
      deployment_context: deployment_context_from(opts, existing_job),
      health_check_interval_ms:
        Application.get_env(
          :mirror_neuron,
          :job_health_check_interval_ms,
          @default_health_check_interval_ms
        ),
      reliability: reliability_from(opts, existing_job),
      pending_workflow_completion: pending_workflow_completion_from(existing_job)
    }

    if status == "pending" do
      persist_job(state)
      EventBus.publish(job_id, %{type: :job_pending, timestamp: Runtime.timestamp()})
      {:ok, state, {:continue, :bootstrap}}
    else
      EventBus.publish(job_id, %{type: :job_recovery_started, timestamp: Runtime.timestamp()})
      {:ok, state, {:continue, :recover}}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    terminate_agent_workers(state)

    with :ok <- wait_for_agents_stopped(state, 5_000),
         {:ok, next_state} <- recover_missing_agents(state),
         :ok <- register_job_services(next_state) do
      persist_job(next_state)

      EventBus.publish(state.job_id, %{
        type: :job_recovered,
        status: next_state.status,
        timestamp: Runtime.timestamp()
      })

      publish_workflow_events(next_state, [])
      schedule_health_check(next_state.health_check_interval_ms)
      {:noreply, next_state}
    else
      {:error, reason} ->
        failed_state =
          finalize_job(
            state,
            "failed",
            %{agent_id: "job_coordinator", error: reason},
            :job_failed,
            %{agent_id: "job_coordinator", reason: reason}
          )

        {:stop, {:shutdown, reason}, failed_state}

      {:error, reason, next_state} ->
        failed_state =
          finalize_job(
            next_state,
            "failed",
            %{agent_id: "job_coordinator", error: reason},
            :job_failed,
            %{agent_id: "job_coordinator", reason: reason}
          )

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    EventBus.publish(state.job_id, %{type: :job_validated, timestamp: Runtime.timestamp()})

    EventBus.publish(state.job_id, %{
      type: :job_scheduled,
      node: to_string(Node.self()),
      timestamp: Runtime.timestamp()
    })

    with {:ok, boot_state} <- start_agents(state),
         {:ok, next_state, workflow_events} <- complete_bootstrap(boot_state) do
      persist_job(next_state)
      EventBus.publish(state.job_id, %{type: :job_running, timestamp: Runtime.timestamp()})
      publish_workflow_events(next_state, workflow_events)
      schedule_health_check(next_state.health_check_interval_ms)
      {:noreply, next_state}
    else
      {:error, {:execution_profile_unavailable, profile, agent_id}, failed_state} ->
        paused_state =
          pause_for_profile_review(
            failed_state,
            profile,
            agent_id,
            "execution profile #{profile} has no eligible runtime nodes"
          )

        {:stop, :normal, paused_state}

      {:error, reason, failed_state} ->
        failed_state =
          finalize_job(failed_state, "failed", %{error: reason}, :job_failed, %{reason: reason})

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  defp complete_bootstrap(state) do
    with :ok <- wait_for_agents_ready(state),
         :ok <- register_runtime_services(state),
         :ok <- seed_entrypoints(state) do
      {workflow_state, workflow_events} = WorkflowLedger.job_running(state.workflow_state)
      {:ok, %{state | status: "running", workflow_state: workflow_state}, workflow_events}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_call(:pause, _from, %{status: "running"} = state) do
    EventBus.publish(state.job_id, %{type: :job_pausing, timestamp: Runtime.timestamp()})
    {workflow_state, workflow_events} = WorkflowLedger.pause(state.workflow_state)
    broadcast_agent_control(state, :pause)

    if WorkflowLedger.enabled?(state.workflow_state) do
      terminate_agent_workers(state, WorkflowLedger.active_agent_ids(state.workflow_state))
    end

    next_state = %{state | status: "paused", workflow_state: workflow_state}
    persist_job(next_state)
    EventBus.publish(state.job_id, %{type: :job_paused, timestamp: Runtime.timestamp()})
    publish_workflow_events(next_state, workflow_events)
    {:reply, {:ok, "paused"}, next_state}
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, "job is not running"}, state}

  @impl true
  def handle_call(:resume, _from, %{status: "paused"} = state) do
    {workflow_state, workflow_events} = WorkflowLedger.resume(state.workflow_state)
    running_state = %{state | status: "running", workflow_state: workflow_state}

    case recover_missing_agents(running_state) do
      {:ok, recovered_state} ->
        broadcast_agent_control(recovered_state, :resume)
        persist_job(recovered_state)
        EventBus.publish(state.job_id, %{type: :job_resumed, timestamp: Runtime.timestamp()})
        publish_workflow_events(recovered_state, workflow_events)
        schedule_health_check(recovered_state.health_check_interval_ms)
        {:reply, {:ok, "resumed"}, recovered_state}

      {:error, reason, failed_state} ->
        {:reply, {:error, reason}, failed_state}
    end
  end

  def handle_call(:resume, _from, %{status: "running"} = state) do
    {:reply, {:ok, "resumed"}, state}
  end

  def handle_call(:resume, _from, state), do: {:reply, {:error, "job is not paused"}, state}

  @impl true
  def handle_call(:cancel, _from, state) do
    broadcast_agent_control(state, :cancel)

    next_state =
      finalize_job(
        state,
        "cancelled",
        %{reason: "cancelled by operator"},
        :job_cancelled,
        %{}
      )

    {:stop, :normal, {:ok, "cancelled"}, next_state}
  end

  @impl true
  def handle_call({:send_message, agent_id, message}, _from, state) do
    envelope = build_external_message(state.job_id, agent_id, message)
    state = refresh_pressure(state)

    case external_input_pressure(state, agent_id) do
      {:retry_later, details} ->
        EventBus.publish(state.job_id, %{
          type: :external_input_rejected,
          agent_id: agent_id,
          payload: details,
          timestamp: Runtime.timestamp()
        })

        {:reply, {:error, {:retry_later, details}}, state}

      :ok ->
        case Runtime.deliver(
               state.job_id,
               agent_id,
               envelope,
               node_backpressure_opts(state, agent_id)
             ) do
          :ok -> {:reply, {:ok, "delivered"}, state}
          {:error, {:backpressure, details}} -> {:reply, {:error, {:retry_later, details}}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:pressure, _from, state) do
    next_state = refresh_pressure(state)
    {:reply, {:ok, pressure_summary(next_state)}, next_state}
  end

  @impl true
  def handle_call({:reschedule_agents, agent_ids, scheduler_plan, reason}, _from, state)
      when state.status in ["running", "paused"] do
    affected_agent_ids = normalize_agent_ids(agent_ids, state)

    if affected_agent_ids == [] do
      {:reply, {:error, :no_matching_agents}, state}
    else
      next_state =
        affected_agent_ids
        |> Enum.reduce(state, fn agent_id, acc ->
          acc
          |> clear_policy_timer({:restart, agent_id})
          |> clear_policy_timer({:reschedule, agent_id})
        end)
        |> put_scheduler_plan(scheduler_plan)

      EventBus.publish(state.job_id, %{
        type: :job_agent_reschedule_started,
        reason: reason,
        affected_agents: affected_agent_ids,
        timestamp: Runtime.timestamp()
      })

      Enum.each(affected_agent_ids, fn agent_id ->
        EventBus.publish(state.job_id, %{
          type: :agent_reschedule_started,
          agent_id: agent_id,
          reason: reason,
          target_node: Scheduler.target_node(scheduler_plan, agent_id),
          timestamp: Runtime.timestamp()
        })
      end)

      terminate_agent_workers(next_state, affected_agent_ids)

      with :ok <- wait_for_agents_stopped(next_state, 5_000, affected_agent_ids),
           {:ok, recovered_state} <- recover_agents(next_state, affected_agent_ids) do
        recovered_state =
          Enum.reduce(affected_agent_ids, recovered_state, fn agent_id, acc ->
            mark_policy_idle(acc, agent_id)
          end)

        persist_job(recovered_state)

        Enum.each(affected_agent_ids, fn agent_id ->
          EventBus.publish(state.job_id, %{
            type: :agent_rescheduled,
            agent_id: agent_id,
            reason: reason,
            target_node: Scheduler.target_node(scheduler_plan, agent_id),
            timestamp: Runtime.timestamp()
          })
        end)

        {:reply,
         {:ok,
          %{
            affected_agents: affected_agent_ids,
            scheduler: scheduler_plan
          }}, recovered_state}
      else
        {:error, failed_reason, failed_state} ->
          {:reply, {:error, failed_reason}, failed_state}

        {:error, failed_reason} ->
          {:reply, {:error, failed_reason}, next_state}
      end
    end
  end

  def handle_call({:reschedule_agents, _agent_ids, _scheduler_plan, _reason}, _from, state) do
    {:reply, {:error, "job is #{state.status}"}, state}
  end

  @impl true
  def handle_call(
        {:deploy_agents, agent_ids, target_manifest, scheduler_plan, deployment_context},
        _from,
        state
      )
      when state.status in ["running", "paused"] do
    affected_agent_ids = normalize_agent_ids(agent_ids, state)

    cond do
      affected_agent_ids == [] ->
        {:reply, {:error, :no_matching_agents}, state}

      not compatible_runtime_topology?(state, target_manifest, scheduler_plan) ->
        {:reply, {:error, "deployment target topology is not compatible with this job"}, state}

      true ->
        next_state =
          state
          |> cancel_policy_timers_for(affected_agent_ids)
          |> put_deployment_target(target_manifest, scheduler_plan, deployment_context)

        EventBus.publish(state.job_id, %{
          type: :deployment_agent_update_started,
          deployment_id: Map.get(deployment_context, "deployment_id"),
          deployment_key: Map.get(deployment_context, "deployment_key"),
          deployment_version: Map.get(deployment_context, "deployment_version"),
          deployment_role: Map.get(deployment_context, "deployment_role"),
          affected_agents: affected_agent_ids,
          timestamp: Runtime.timestamp()
        })

        terminate_agent_workers(next_state, affected_agent_ids)

        with :ok <- wait_for_agents_stopped(next_state, 5_000, affected_agent_ids),
             {:ok, deployed_state} <- deploy_agents_now(next_state, affected_agent_ids),
             :ok <- register_job_services(deployed_state) do
          persist_job(deployed_state)

          EventBus.publish(state.job_id, %{
            type: :deployment_agent_update_completed,
            deployment_id: Map.get(deployment_context, "deployment_id"),
            deployment_key: Map.get(deployment_context, "deployment_key"),
            deployment_version: Map.get(deployment_context, "deployment_version"),
            deployment_role: Map.get(deployment_context, "deployment_role"),
            affected_agents: affected_agent_ids,
            timestamp: Runtime.timestamp()
          })

          {:reply,
           {:ok,
            %{
              affected_agents: affected_agent_ids,
              deployment: deployment_context,
              scheduler: scheduler_plan
            }}, deployed_state}
        else
          {:error, failed_reason, failed_state} ->
            {:reply, {:error, failed_reason}, failed_state}

          {:error, failed_reason} ->
            {:reply, {:error, failed_reason}, next_state}
        end
    end
  end

  def handle_call(
        {:deploy_agents, _agent_ids, _target_manifest, _scheduler_plan, _context},
        _from,
        state
      ) do
    {:reply, {:error, "job is #{state.status}"}, state}
  end

  @impl true
  def handle_info({:agent_event, agent_id, event_type, payload}, state) do
    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.on_agent_event(state.workflow_state, agent_id, event_type, payload)

    state = %{state | workflow_state: workflow_state}

    EventBus.publish(state.job_id, %{
      type: event_type,
      agent_id: agent_id,
      payload: payload,
      timestamp: Runtime.timestamp()
    })

    publish_workflow_events(state, workflow_events)

    case apply_workflow_actions(state, workflow_actions) do
      {:ok, next_state} ->
        continue_or_complete_workflow(next_state)

      {:fail_job, step_id, reason, failed_state} ->
        failed_state =
          finalize_job(
            failed_state,
            "failed",
            %{step_id: step_id, error: reason},
            :job_failed,
            %{step_id: step_id, reason: reason}
          )

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  def handle_info({:workflow_message_received, agent_id, message}, state) do
    {workflow_state, workflow_events} =
      WorkflowLedger.on_message_received(state.workflow_state, agent_id, message)

    next_state = %{state | workflow_state: workflow_state}
    publish_workflow_events(next_state, workflow_events)
    continue_or_complete_workflow(next_state)
  end

  def handle_info({:workflow_message_acked, agent_id, message}, state) do
    {workflow_state, workflow_events} =
      WorkflowLedger.on_message_acked(state.workflow_state, agent_id, message)

    next_state = %{state | workflow_state: workflow_state}
    publish_workflow_events(next_state, workflow_events)
    continue_or_complete_workflow(next_state)
  end

  def handle_info({:agent_checkpoint, agent_id, snapshot}, state) do
    case RedisStore.persist_agent(state.job_id, agent_id, snapshot) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist agent checkpoint for #{state.job_id}/#{agent_id}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_info({:agent_pressure, agent_id, pressure}, state) do
    previous = Map.get(state.pressure, agent_id)
    next_state = put_in(state.pressure[agent_id], pressure)

    if pressure_event_changed?(previous, pressure) do
      EventBus.publish(state.job_id, %{
        type: :backpressure_state,
        agent_id: agent_id,
        payload: pressure,
        timestamp: Runtime.timestamp()
      })
    end

    {:noreply, next_state}
  end

  def handle_info({:agent_completed_run, agent_id, result}, state) do
    cond do
      workflow_agent?(state, agent_id) ->
        handle_workflow_agent_completed_run(state, agent_id, result)

      workflow_controls_runtime?(state) ->
        handle_workflow_sink_completed_run(state, agent_id, result)

      true ->
        case job_type(state) do
          "service" ->
            restart_service_agent(state, agent_id, result)

          "system" ->
            restart_system_target(state, agent_id, result)

          "sysbatch" ->
            complete_sysbatch_target(state, agent_id, result)

          _batch ->
            next_state =
              finalize_job(
                state,
                "completed",
                %{agent_id: agent_id, output: result},
                :job_completed,
                %{agent_id: agent_id, result: result}
              )

            {:stop, :normal, next_state}
        end
    end
  end

  def handle_info({:agent_failed, agent_id, reason}, state) do
    if workflow_agent_active?(state, agent_id) do
      handle_workflow_agent_failed(state, agent_id, reason)
    else
      handle_runtime_agent_failed(state, agent_id, reason)
    end
  end

  def handle_info({:policy_restart, agent_id, reason}, state) do
    next_state = clear_policy_timer(state, {:restart, agent_id})

    case restart_agents_now(next_state, [agent_id], reason) do
      {:ok, recovered_state} ->
        recovered_state = mark_policy_idle(recovered_state, agent_id)
        persist_job(recovered_state)
        {:noreply, recovered_state}

      {:error, failed_reason, failed_state} ->
        case schedule_agent_restarts(failed_state, [agent_id], failed_reason) do
          {:ok, retry_state} ->
            {:noreply, retry_state}

          {:error, final_reason, final_state} ->
            failed_state =
              finalize_job(
                final_state,
                "failed",
                %{agent_id: agent_id, error: final_reason},
                :job_failed,
                %{agent_id: agent_id, reason: final_reason}
              )

            {:stop, {:shutdown, final_reason}, failed_state}
        end
    end
  end

  def handle_info({:policy_reschedule, agent_ids, reason}, state) do
    affected_agent_ids = normalize_agent_ids(agent_ids, state)

    next_state =
      Enum.reduce(affected_agent_ids, state, fn agent_id, acc ->
        clear_policy_timer(acc, {:reschedule, agent_id})
      end)

    start_reschedule_task(next_state, affected_agent_ids, reason)
    {:noreply, next_state}
  end

  def handle_info(:health_check, %{status: status} = state)
      when status in ["running", "paused"] do
    state = refresh_pressure(state)

    case schedule_missing_agents(state) do
      {:ok, next_state} ->
        case reconcile_workflow(next_state) do
          {:ok, reconciled_state} ->
            case continue_or_complete_workflow(reconciled_state) do
              {:noreply, continued_state} ->
                schedule_health_check(continued_state.health_check_interval_ms)
                {:noreply, continued_state}

              {:stop, _reason, _completed_state} = stop ->
                stop
            end

          {:fail_job, step_id, reason, failed_state} ->
            failed_state =
              finalize_job(
                failed_state,
                "failed",
                %{step_id: step_id, error: reason},
                :job_failed,
                %{step_id: step_id, reason: reason}
              )

            {:stop, {:shutdown, reason}, failed_state}
        end

      {:error, reason, next_state} ->
        failed_state =
          finalize_job(
            next_state,
            "failed",
            %{agent_id: "job_coordinator", error: reason},
            :job_failed,
            %{agent_id: "job_coordinator", reason: reason}
          )

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  def handle_info(:health_check, state), do: {:noreply, state}

  defp restart_service_agent(state, agent_id, result) do
    EventBus.publish(state.job_id, %{
      type: :service_agent_completed,
      agent_id: agent_id,
      result: result,
      timestamp: Runtime.timestamp()
    })

    terminate_agent_workers(state, [agent_id])
    {:ok, next_state} = schedule_agent_restarts(state, [agent_id], "service agent completed")
    {:noreply, next_state}
  end

  defp restart_system_target(state, agent_id, result) do
    target = system_target_for_agent(state, agent_id)
    agent_ids = agents_for_system_target(state, target, [agent_id])

    EventBus.publish(state.job_id, %{
      type: :system_target_completed,
      agent_id: agent_id,
      system_target: target,
      result: result,
      timestamp: Runtime.timestamp()
    })

    terminate_agent_workers(state, agent_ids)
    {:ok, next_state} = schedule_agent_restarts(state, agent_ids, "system target completed")
    {:noreply, next_state}
  end

  defp complete_sysbatch_target(state, agent_id, result) do
    target = system_target_for_agent(state, agent_id)
    agent_ids = agents_for_system_target(state, target, [agent_id])

    next_state =
      state
      |> put_completed_agent(agent_id)
      |> put_completed_system_target(target)
      |> put_sysbatch_result(agent_id, target, result)

    EventBus.publish(state.job_id, %{
      type: :sysbatch_target_completed,
      agent_id: agent_id,
      system_target: target,
      result: result,
      completed_targets: MapSet.to_list(next_state.completed_system_targets),
      timestamp: Runtime.timestamp()
    })

    terminate_agent_workers(next_state, agent_ids)

    if all_system_targets_completed?(next_state) do
      completed_state =
        finalize_job(
          next_state,
          "completed",
          sysbatch_result(next_state),
          :job_completed,
          %{agent_id: agent_id, result: sysbatch_result(next_state)}
        )

      {:stop, :normal, completed_state}
    else
      persist_job(next_state)
      {:noreply, next_state}
    end
  end

  defp handle_workflow_agent_failed(state, agent_id, reason) do
    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.on_agent_failed(state.workflow_state, agent_id, reason)

    next_state = %{state | workflow_state: workflow_state}
    publish_workflow_events(next_state, workflow_events)

    case apply_workflow_actions(next_state, workflow_actions) do
      {:ok, recovered_state} ->
        continue_or_complete_workflow(recovered_state)

      {:fail_job, step_id, failed_reason, failed_state} ->
        failed_state =
          finalize_job(
            failed_state,
            "failed",
            %{step_id: step_id, agent_id: agent_id, error: failed_reason},
            :job_failed,
            %{step_id: step_id, agent_id: agent_id, reason: failed_reason}
          )

        {:stop, {:shutdown, failed_reason}, failed_state}
    end
  end

  defp handle_workflow_agent_completed_run(state, agent_id, result) do
    reason = "workflow step agent cannot complete the whole run"

    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.on_agent_failed(state.workflow_state, agent_id, reason)

    next_state = %{state | workflow_state: workflow_state}

    EventBus.publish(state.job_id, %{
      type: :workflow_run_completion_rejected,
      agent_id: agent_id,
      payload: %{"reason" => reason, "result" => result},
      timestamp: Runtime.timestamp()
    })

    publish_workflow_events(next_state, workflow_events)

    case apply_workflow_actions(next_state, workflow_actions) do
      {:ok, recovered_state} ->
        persist_job(recovered_state)
        {:noreply, recovered_state}

      {:fail_job, step_id, failed_reason, failed_state} ->
        failed_state =
          finalize_job(
            failed_state,
            "failed",
            %{step_id: step_id, agent_id: agent_id, error: failed_reason},
            :job_failed,
            %{step_id: step_id, agent_id: agent_id, reason: failed_reason}
          )

        {:stop, {:shutdown, failed_reason}, failed_state}
    end
  end

  defp handle_workflow_sink_completed_run(state, agent_id, result) do
    cond do
      not terminal_sink?(state, agent_id) ->
        EventBus.publish(state.job_id, %{
          type: :workflow_completion_ignored,
          agent_id: agent_id,
          payload: %{
            reason: "agent is not a declared terminal sink",
            result: result
          },
          timestamp: Runtime.timestamp()
        })

        persist_job(state)
        {:noreply, state}

      WorkflowLedger.completed?(state.workflow_state) ->
        next_state =
          finalize_job(
            state,
            "completed",
            %{agent_id: agent_id, output: result, workflow_state: state.workflow_state},
            :job_completed,
            %{agent_id: agent_id, result: result, workflow: true}
          )

        {:stop, :normal, next_state}

      true ->
        timestamp = Runtime.timestamp()

        EventBus.publish(state.job_id, %{
          type: :workflow_completion_deferred,
          agent_id: agent_id,
          payload: %{
            reason: "workflow steps are not terminal",
            result: result
          },
          timestamp: timestamp
        })

        next_state = %{
          state
          | pending_workflow_completion: %{
              "agent_id" => agent_id,
              "result" => result,
              "received_at" => timestamp
            }
        }

        persist_job(next_state)
        {:noreply, next_state}
    end
  end

  defp continue_or_complete_workflow(state) do
    case pending_workflow_completion(state) do
      nil ->
        persist_job(state)
        {:noreply, state}

      %{"agent_id" => agent_id, "result" => result}
      when is_binary(agent_id) ->
        if WorkflowLedger.completed?(state.workflow_state) and terminal_sink?(state, agent_id) do
          EventBus.publish(state.job_id, %{
            type: :workflow_completion_resumed,
            agent_id: agent_id,
            payload: %{"reason" => "workflow steps are terminal"},
            timestamp: Runtime.timestamp()
          })

          next_state =
            state
            |> Map.put(:pending_workflow_completion, nil)
            |> finalize_job(
              "completed",
              %{agent_id: agent_id, output: result, workflow_state: state.workflow_state},
              :job_completed,
              %{agent_id: agent_id, result: result, workflow: true, deferred: true}
            )

          {:stop, :normal, next_state}
        else
          persist_job(state)
          {:noreply, state}
        end

      _other ->
        next_state = %{state | pending_workflow_completion: nil}
        persist_job(next_state)
        {:noreply, next_state}
    end
  end

  defp pending_workflow_completion(%{pending_workflow_completion: pending})
       when is_map(pending) do
    pending
  end

  defp pending_workflow_completion(_state), do: nil

  defp handle_runtime_agent_failed(state, agent_id, reason) do
    case restart_failed_agent(state, agent_id, reason) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, failed_reason, next_state} ->
        failed_state =
          finalize_job(
            next_state,
            "failed",
            %{agent_id: agent_id, error: failed_reason},
            :job_failed,
            %{agent_id: agent_id, reason: failed_reason}
          )

        {:stop, {:shutdown, failed_reason}, failed_state}
    end
  end

  defp restart_failed_agent(state, agent_id, reason) do
    terminate_agent_workers(state, [agent_id])
    schedule_agent_restarts(state, [agent_id], inspect(reason))
  end

  defp restart_agents_now(state, agent_ids, reason) do
    agent_ids = normalize_agent_ids(agent_ids, state)
    terminate_agent_workers(state, agent_ids)

    with :ok <- wait_for_agents_stopped(state, 5_000, agent_ids),
         {:ok, next_state} <- recover_agents(state, agent_ids) do
      persist_job(next_state)

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

  defp schedule_missing_agents(state) do
    Enum.reduce_while(state.agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      cond do
        agent_completed?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        agent_ready?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        ignorable_missing_agent?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        workflow_agent_active?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        pending_policy_action?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        true ->
          case schedule_agent_restarts(acc_state, [agent_id], "agent missing during health check") do
            {:ok, next_state} -> {:cont, {:ok, next_state}}
            {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
          end
      end
    end)
  end

  defp reconcile_workflow(state) do
    {workflow_state, workflow_events, workflow_actions} =
      WorkflowLedger.reconcile(state.workflow_state)

    next_state = %{state | workflow_state: workflow_state}
    publish_workflow_events(next_state, workflow_events)

    case apply_workflow_actions(next_state, workflow_actions) do
      {:ok, applied_state} ->
        persist_job(applied_state)
        {:ok, applied_state}

      {:fail_job, step_id, reason, failed_state} ->
        {:fail_job, step_id, reason, failed_state}
    end
  end

  defp apply_workflow_actions(state, actions) do
    Enum.reduce_while(actions, {:ok, state}, fn
      {:terminate_agent, nil, _reason}, {:ok, acc_state} ->
        {:cont, {:ok, acc_state}}

      {:terminate_agent, agent_id, _reason}, {:ok, acc_state} ->
        terminate_agent_workers(acc_state, [agent_id])
        {:cont, {:ok, acc_state}}

      {:redeliver, step_id, agent_id, message}, {:ok, acc_state} ->
        case ensure_workflow_agent_ready(acc_state, agent_id) do
          {:ok, ready_state} ->
            case Runtime.deliver(
                   ready_state.job_id,
                   agent_id,
                   message,
                   node_backpressure_opts(ready_state, agent_id)
                 ) do
              :ok ->
                {:cont, {:ok, ready_state}}

              {:error, reason} ->
                {workflow_state, events} =
                  WorkflowLedger.mark_delivery_failed(
                    ready_state.workflow_state,
                    message,
                    step_id,
                    reason
                  )

                failed_state = %{ready_state | workflow_state: workflow_state}
                publish_workflow_events(failed_state, events)
                {:cont, {:ok, failed_state}}
            end

          {:error, reason, failed_state} ->
            {:halt, {:fail_job, step_id, reason, failed_state}}
        end

      {:fail_job, step_id, reason}, {:ok, acc_state} ->
        {:halt, {:fail_job, step_id, reason, acc_state}}
    end)
  end

  defp ensure_workflow_agent_ready(state, agent_id) do
    cond do
      is_nil(agent_id) ->
        {:error, "workflow retry has no target agent", state}

      agent_ready?(state, agent_id) ->
        {:ok, state}

      true ->
        recover_agent(state, agent_id)
    end
  end

  defp workflow_agent_active?(state, agent_id) do
    workflow_agent?(state, agent_id) and
      agent_id in WorkflowLedger.active_agent_ids(state.workflow_state)
  end

  defp workflow_agent?(state, agent_id) do
    WorkflowLedger.enabled?(state.workflow_state) and
      is_binary(WorkflowLedger.step_for_agent(state.workflow_state, agent_id))
  end

  defp workflow_controls_runtime?(state) do
    workflow_agent_ids =
      state.workflow_state
      |> WorkflowLedger.agent_to_step()
      |> Map.keys()
      |> MapSet.new()

    runtime_agent_ids = MapSet.new(state.agent_ids)

    WorkflowLedger.enabled?(state.workflow_state) and
      not MapSet.disjoint?(workflow_agent_ids, runtime_agent_ids)
  end

  defp terminal_sink?(state, agent_id) do
    case Map.get(state.nodes_by_id, agent_id) do
      %{config: config} when is_map(config) ->
        Map.get(config, "terminal_sink") == true and Map.get(config, "complete_run") == true

      _ ->
        false
    end
  end

  defp schedule_agent_restarts(state, agent_ids, reason) do
    agent_ids = normalize_agent_ids(agent_ids, state)

    Enum.reduce_while(agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      policy = restart_policy(acc_state, agent_id)
      history = policy_history(acc_state, agent_id, "restart")

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
        policy_history(state, agent_id, "restart"),
        "restart",
        reason
      )

    next_state =
      state
      |> put_policy_history(agent_id, "restart", history)
      |> put_policy_agent_fields(agent_id, %{
        "last_reason" => stringify(reason),
        "next_action" => "restart",
        "next_eligible_at" => next_eligible_at,
        "exhausted_reason" => nil,
        "restart_attempts" => LifecyclePolicy.active_attempt_count(policy, history)
      })
      |> schedule_policy_timer(
        {:restart, agent_id},
        {:policy_restart, agent_id, reason},
        delay_ms
      )

    persist_job(next_state)

    EventBus.publish(state.job_id, %{
      type: :agent_restart_scheduled,
      agent_id: agent_id,
      reason: stringify(reason),
      job_type: job_type(state),
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
      |> put_policy_agent_fields(agent_id, %{
        "last_reason" => stringify(reason),
        "next_action" => "restart",
        "next_eligible_at" => wait_until,
        "exhausted_reason" => exhaustion["reason"],
        "restart_attempts" =>
          LifecyclePolicy.active_attempt_count(policy, policy_history(state, agent_id, "restart"))
      })
      |> schedule_policy_timer({:restart, agent_id}, {:policy_restart, agent_id, reason}, wait_ms)

    persist_job(next_state)

    EventBus.publish(state.job_id, %{
      type: :agent_restart_deferred,
      agent_id: agent_id,
      reason: stringify(reason),
      exhausted_reason: exhaustion["reason"],
      retry_at: wait_until,
      delay_ms: wait_ms,
      timestamp: Runtime.timestamp()
    })

    {:ok, next_state}
  end

  defp handle_restart_exhausted(state, agent_id, reason, _policy, exhaustion) do
    effective_policy = effective_recovery_policy(state)

    cond do
      effective_policy == "manual_recover" ->
        {:ok, pause_for_policy_review(state, agent_id, "manual recovery policy requires review")}

      effective_policy == "cluster_recover" ->
        schedule_agent_reschedule(state, agent_id, reason, exhaustion)

      job_type(state) in ["service", "system"] ->
        {:ok,
         pause_for_policy_review(
           state,
           agent_id,
           "restart attempts exhausted and cluster recovery is not active"
         )}

      true ->
        {:error, "agent #{agent_id} restart attempts exhausted: #{exhaustion["reason"]}", state}
    end
  end

  defp schedule_agent_reschedule(state, agent_id, reason, restart_exhaustion) do
    policy = reschedule_policy(state, agent_id)
    history = policy_history(state, agent_id, "reschedule")

    case LifecyclePolicy.attempt_decision(policy, history) do
      {:allowed, decision} ->
        delay_ms = Map.get(decision, "delay_ms", 0)
        next_eligible_at = LifecyclePolicy.iso_after(delay_ms)

        history =
          LifecyclePolicy.append_history(
            history,
            "reschedule",
            "#{stringify(reason)} after restart exhaustion"
          )

        next_state =
          state
          |> put_policy_history(agent_id, "reschedule", history)
          |> put_policy_agent_fields(agent_id, %{
            "last_reason" => stringify(reason),
            "next_action" => "reschedule",
            "next_eligible_at" => next_eligible_at,
            "exhausted_reason" => restart_exhaustion["reason"],
            "reschedule_attempts" => LifecyclePolicy.active_attempt_count(policy, history)
          })
          |> schedule_policy_timer(
            {:reschedule, agent_id},
            {:policy_reschedule, [agent_id], stringify(reason)},
            delay_ms
          )

        persist_job(next_state)

        EventBus.publish(state.job_id, %{
          type: :agent_reschedule_scheduled,
          agent_id: agent_id,
          reason: stringify(reason),
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

        if job_type(state) in ["service", "system"] do
          {:ok, pause_for_policy_review(state, agent_id, reason)}
        else
          {:error, reason, state}
        end
    end
  end

  defp start_reschedule_task(state, [], _reason), do: state

  defp start_reschedule_task(state, affected_agent_ids, reason) do
    task = fn ->
      MirrorNeuron.Cluster.Reconciler.reschedule_agents(
        state.job_id,
        affected_agent_ids,
        reason: reason,
        skip_reschedule_policy: true,
        skip_reschedule_policy_record: true
      )
    end

    case Process.whereis(MirrorNeuron.Runtime.RecoveryTaskSupervisor) do
      nil -> Task.start(task)
      _pid -> Task.Supervisor.start_child(MirrorNeuron.Runtime.RecoveryTaskSupervisor, task)
    end

    state
  end

  defp start_agents(state), do: start_agents(state, [])

  defp start_agents(state, excluded_nodes) do
    case do_start_agents(state) do
      :ok ->
        {:ok, state}

      {:error, {:target_node_unavailable, target_node, agent_id}} ->
        if target_node in excluded_nodes do
          {:error,
           "failed to start agent #{agent_id}: {:target_node_unavailable, #{inspect(target_node)}}",
           state}
        else
          terminate_agent_workers(state)
          _ = wait_for_agents_stopped(state, 5_000)

          case replan_after_unavailable_target(state, target_node, agent_id) do
            {:ok, next_state} ->
              start_agents(next_state, [target_node | excluded_nodes])

            {:error, reason} ->
              {:error, reason, state}
          end
        end

      {:error, {:execution_profile_unavailable, profile, agent_id}} ->
        {:error, {:execution_profile_unavailable, profile, agent_id}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp do_start_agents(state) do
    Enum.reduce_while(state.runtime_nodes, :ok, fn node, :ok ->
      case start_agent(state, node.node_id) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, {:already_started, _pid}} ->
          {:cont, :ok}

        {:error, {:no_eligible_execution_profile_nodes, profile}} ->
          {:halt, {:error, {:execution_profile_unavailable, profile, node.node_id}}}

        {:error, {:target_node_unavailable, target_node}} ->
          {:halt, {:error, {:target_node_unavailable, target_node, node.node_id}}}

        {:error, reason} ->
          {:halt, {:error, "failed to start agent #{node.node_id}: #{inspect(reason)}"}}
      end
    end)
  end

  defp replan_after_unavailable_target(state, target_node, agent_id) do
    scheduler_opts =
      state.opts
      |> Keyword.delete(:scheduler_plan)
      |> Keyword.update(:exclude_nodes, [target_node], fn nodes ->
        [target_node | List.wrap(nodes)] |> Enum.map(&to_string/1) |> Enum.uniq()
      end)
      |> Keyword.update(:ignore_job_ids, [state.job_id], fn job_ids ->
        [state.job_id | List.wrap(job_ids)] |> Enum.map(&to_string/1) |> Enum.uniq()
      end)

    case Scheduler.plan(state.manifest, scheduler_opts) do
      {:ok, scheduler_plan} ->
        next_state = put_runtime_scheduler_plan(state, scheduler_plan)

        EventBus.publish(state.job_id, %{
          type: :job_scheduler_replanned,
          reason: "scheduled target #{target_node} was unavailable while starting #{agent_id}",
          excluded_nodes: [target_node],
          scheduler: scheduler_plan,
          timestamp: Runtime.timestamp()
        })

        {:ok, next_state}

      {:error, reason} ->
        {:error,
         "failed to replan after unavailable target #{target_node} for agent #{agent_id}: #{inspect(reason)}"}
    end
  end

  defp refresh_pressure(state) do
    pressure =
      Enum.reduce(state.agent_ids, state.pressure, fn agent_id, acc ->
        case agent_pressure_snapshot(state, agent_id) do
          nil -> acc
          snapshot -> Map.put(acc, agent_id, snapshot)
        end
      end)

    pressure
    |> Enum.filter(fn {agent_id, snapshot} ->
      pressure_event_changed?(Map.get(state.pressure, agent_id), snapshot)
    end)
    |> Enum.each(fn {agent_id, snapshot} ->
      EventBus.publish(state.job_id, %{
        type: :backpressure_state,
        agent_id: agent_id,
        payload: snapshot,
        timestamp: Runtime.timestamp()
      })
    end)

    %{state | pressure: pressure}
  end

  defp pressure_event_changed?(previous, pressure) when is_map(previous) and is_map(pressure) do
    Backpressure.pressured?(pressure) and
      (Map.get(previous, "status") != Map.get(pressure, "status") or
         Map.get(previous, "queue_depth") != Map.get(pressure, "queue_depth"))
  end

  defp pressure_event_changed?(_previous, pressure) do
    Backpressure.pressured?(pressure)
  end

  defp agent_pressure_snapshot(state, agent_id) do
    with {:ok, pid} <- lookup_registered_agent(state.job_id, agent_id),
         node when is_map(node) <- Map.get(state.nodes_by_id, agent_id) do
      queue_depth = Backpressure.process_queue_depth(pid)
      Backpressure.snapshot(agent_id, node, queue_depth, [], Map.get(state.pressure, agent_id))
    else
      _ -> nil
    end
  end

  defp external_input_pressure(state, agent_id) do
    impacted_agents = [agent_id | Map.get(state.downstream_by_node, agent_id, [])]

    state.pressure
    |> Map.take(impacted_agents)
    |> Enum.find(fn {_id, snapshot} -> Backpressure.pressured?(snapshot) end)
    |> case do
      nil ->
        :ok

      {pressured_agent_id, snapshot} ->
        {:retry_later,
         Backpressure.retry_later_reason(snapshot, %{
           "target_agent_id" => agent_id,
           "pressured_agent_id" => pressured_agent_id,
           "affected_agents" => impacted_agents,
           "accepted" => false
         })}
    end
  end

  defp pressure_summary(state) do
    %{
      "job_id" => state.job_id,
      "pressured" =>
        state.pressure
        |> Enum.filter(fn {_id, snapshot} -> Backpressure.pressured?(snapshot) end)
        |> Enum.map(fn {id, snapshot} -> Map.put(snapshot, "agent_id", id) end),
      "agents" => state.pressure
    }
  end

  defp seed_entrypoints(state) do
    inputs = state.manifest.initial_inputs

    Enum.reduce_while(state.runtime_entrypoints, :ok, fn agent_id, :ok ->
      source_agent_id = Map.get(state.source_agent_ids, agent_id, agent_id)

      payloads =
        Map.get(inputs, agent_id) ||
          Map.get(inputs, source_agent_id) ||
          Map.get(inputs, "__entrypoints__") ||
          [%{}]

      result =
        Enum.reduce_while(payloads, :ok, fn payload, :ok ->
          message =
            Message.normalize!(
              payload,
              job_id: state.job_id,
              from: "runtime",
              to: agent_id,
              type: "init",
              class: "command",
              correlation_id: unique_id()
            )

          message = WorkflowLedger.decorate_message(state.workflow_state, agent_id, message)

          case Runtime.deliver(state.job_id, agent_id, message) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp register_runtime_services(state) do
    with :ok <- register_job_services(state) do
      Enum.reduce_while(state.agent_ids, :ok, fn agent_id, :ok ->
        case register_agent_services(state, agent_id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp register_job_services(state) do
    services =
      ServiceSpec.service_instances_for_job(state.manifest, state.job_id,
        bundle_root: runtime_bundle_root(state)
      )

    register_services(state, services)
  end

  defp register_agent_services(state, agent_id) do
    node = Map.fetch!(state.nodes_by_id, agent_id)
    target_node = Scheduler.target_node(scheduler_plan(state), agent_id) || to_string(Node.self())

    services =
      ServiceSpec.service_instances_for_agent(
        state.manifest,
        state.job_id,
        node,
        target_node,
        bundle_root: runtime_bundle_root(state)
      )

    register_services(state, services)
  end

  defp register_services(_state, []), do: :ok

  defp register_services(state, services) do
    services = Enum.map(services, &put_service_deployment_context(&1, state.deployment_context))

    case ServiceRegistry.register_many(services) do
      {:ok, registered} ->
        Enum.each(registered, fn service ->
          EventBus.publish(state.job_id, %{
            type: :service_registered,
            service_id: Map.get(service, "id"),
            service_name: Map.get(service, "name"),
            agent_id: Map.get(service, "agent_id"),
            node: Map.get(service, "node"),
            status: Map.get(service, "status"),
            timestamp: Runtime.timestamp()
          })
        end)

        :ok

      {:error, reason} ->
        {:error, "failed to register services: #{inspect(reason)}"}
    end
  end

  defp put_service_deployment_context(service, context)
       when is_map(context) and map_size(context) > 0 do
    service
    |> Map.put("deployment_id", Map.get(context, "deployment_id"))
    |> Map.put("deployment_key", Map.get(context, "deployment_key"))
    |> Map.put("deployment_version", Map.get(context, "deployment_version"))
    |> Map.put("deployment_role", Map.get(context, "deployment_role", "primary"))
  end

  defp put_service_deployment_context(service, _context), do: service

  defp wait_for_agents_ready(state, timeout_ms \\ 20_000) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agents_ready(state, started_at, timeout_ms)
  end

  defp recover_missing_agents(state) do
    Enum.reduce_while(state.agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      cond do
        agent_completed?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        agent_ready?(acc_state, agent_id) ->
          {:cont, {:ok, acc_state}}

        true ->
          case recover_agent(acc_state, agent_id) do
            {:ok, next_state} -> {:cont, {:ok, next_state}}
            {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
          end
      end
    end)
  end

  defp recover_agents(state, agent_ids) do
    Enum.reduce_while(agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      if agent_completed?(acc_state, agent_id) do
        {:cont, {:ok, acc_state}}
      else
        case recover_agent(acc_state, agent_id) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
        end
      end
    end)
  end

  defp deploy_agents_now(state, agent_ids) do
    Enum.reduce_while(agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      case start_agent(acc_state, agent_id, nil) do
        {:ok, _pid} ->
          with :ok <- wait_for_agent_ready(acc_state, agent_id, 30_000),
               :ok <- register_agent_services(acc_state, agent_id) do
            {:cont, {:ok, mark_policy_idle(acc_state, agent_id)}}
          else
            {:error, reason} -> {:halt, {:error, reason, acc_state}}
          end

        {:error, {:already_started, _pid}} ->
          {:cont, {:ok, acc_state}}

        {:error, reason} ->
          {:halt, {:error, "failed to deploy agent #{agent_id}: #{inspect(reason)}", acc_state}}
      end
    end)
  end

  defp recover_agent(state, agent_id) do
    recovery_snapshot =
      case RedisStore.fetch_agent(state.job_id, agent_id) do
        {:ok, snapshot} -> snapshot
        _ -> nil
      end

    attempt =
      max(
        LifecyclePolicy.active_attempt_count(
          restart_policy(state, agent_id),
          policy_history(state, agent_id, "restart")
        ),
        1
      )

    EventBus.publish(state.job_id, %{
      type: :agent_recovery_started,
      agent_id: agent_id,
      attempt: attempt,
      timestamp: Runtime.timestamp()
    })

    case start_agent(state, agent_id, recovery_snapshot) do
      {:ok, _pid} ->
        wait_result = wait_for_agent_ready(state, agent_id, 30_000)

        case wait_result do
          :ok ->
            case register_agent_services(state, agent_id) do
              :ok ->
                EventBus.publish(state.job_id, %{
                  type: :agent_recovered,
                  agent_id: agent_id,
                  attempt: attempt,
                  timestamp: Runtime.timestamp()
                })

                {:ok, mark_policy_idle(state, agent_id)}

              {:error, reason} ->
                {:error, reason, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, {:already_started, _pid}} ->
        {:ok, state}

      {:error, reason} ->
        {:error, "failed to recover agent #{agent_id}: #{inspect(reason)}", state}
    end
  end

  defp start_agent(state, agent_id, recovery_snapshot \\ nil, retry_count \\ 0) do
    node =
      state.nodes_by_id
      |> Map.fetch!(agent_id)
      |> apply_execution_profile()

    recovery_snapshot = align_recovery_snapshot_with_job_status(state, recovery_snapshot)
    execution_profile = Profile.profile_name(node.config)

    spec =
      AgentWorker.child_spec(
        {state.job_id, node, Map.get(state.outbound_edges_by_node, agent_id, []),
         Map.get(state.inbound_edges_by_node, agent_id, []), self(), agent_runtime_context(state),
         recovery_snapshot}
      )
      |> Map.put(:mirror_neuron_execution_profile, execution_profile)
      |> Map.put(
        :mirror_neuron_target_node,
        Scheduler.target_node(scheduler_plan(state), agent_id)
      )

    case start_agent_on_target(spec, Scheduler.target_node(scheduler_plan(state), agent_id)) do
      {:error, {:already_started, _pid}} when retry_count < 10 ->
        Process.sleep(100)
        start_agent(state, agent_id, recovery_snapshot, retry_count + 1)

      {:error, {:target_node_unavailable, _target_node}} when retry_count < 50 ->
        Process.sleep(200)
        start_agent(state, agent_id, recovery_snapshot, retry_count + 1)

      other ->
        other
    end
  end

  defp start_agent_on_target(spec, nil), do: start_agent_here(spec)
  defp start_agent_on_target(spec, ""), do: start_agent_here(spec)

  defp start_agent_on_target(spec, target_node) when is_binary(target_node) do
    case MirrorNeuron.SafeAccess.node_name_to_atom(target_node) do
      {:ok, node} -> start_agent_on_target(spec, node)
      {:error, _reason} -> {:error, {:target_node_unavailable, target_node}}
    end
  end

  defp start_agent_on_target(spec, target_node) when is_atom(target_node) do
    cond do
      target_node == Node.self() ->
        start_agent_here(spec)

      Node.connect(target_node) ->
        case :rpc.call(
               target_node,
               DynamicSupervisor,
               :start_child,
               [MirrorNeuron.Runtime.LocalAgentSupervisor, spec],
               30_000
             ) do
          {:ok, _pid} = ok -> ok
          {:error, {:already_started, _pid}} = already_started -> already_started
          {:error, reason} -> {:error, reason}
          {:badrpc, reason} -> {:error, reason}
          other -> {:error, other}
        end

      true ->
        {:error, {:target_node_unavailable, to_string(target_node)}}
    end
  end

  defp start_agent_here(spec) do
    DynamicSupervisor.start_child(MirrorNeuron.Runtime.LocalAgentSupervisor, spec)
  end

  defp apply_execution_profile(%{config: config} = node) do
    %{node | config: Profile.apply_to_config(config)}
  end

  defp apply_execution_profile(node), do: node

  defp wait_for_agents_stopped(state, timeout_ms) do
    wait_for_agents_stopped(state, timeout_ms, state.agent_ids)
  end

  defp wait_for_agents_stopped(state, timeout_ms, agent_ids) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agents_stopped(state, started_at, timeout_ms, agent_ids)
  end

  defp do_wait_for_agents_stopped(state, started_at, timeout_ms, agent_ids) do
    running_agents = Enum.filter(agent_ids, &agent_ready?(state, &1))

    case running_agents do
      [] ->
        :ok

      _agents ->
        if System.monotonic_time(:millisecond) - started_at > timeout_ms do
          {:error, "timed out waiting for existing agents to stop before recovery"}
        else
          Process.sleep(25)
          do_wait_for_agents_stopped(state, started_at, timeout_ms, agent_ids)
        end
    end
  end

  defp align_recovery_snapshot_with_job_status(%{status: "paused"}, nil) do
    %{"metadata" => %{"paused" => true}}
  end

  defp align_recovery_snapshot_with_job_status(%{status: status}, snapshot)
       when status in ["running", "paused"] and is_map(snapshot) do
    metadata =
      snapshot
      |> Map.get("metadata", %{})
      |> Map.put("paused", status == "paused")

    Map.put(snapshot, "metadata", metadata)
  end

  defp align_recovery_snapshot_with_job_status(_state, snapshot), do: snapshot

  defp wait_for_agent_ready(state, agent_id, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms)
  end

  defp do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms) do
    if agent_ready?(state, agent_id) do
      :ok
    else
      if System.monotonic_time(:millisecond) - started_at > timeout_ms do
        {:error, "timed out waiting for recovered agent #{agent_id} to register"}
      else
        Process.sleep(25)
        do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms)
      end
    end
  end

  defp agent_ready?(state, agent_id) do
    with {:ok, pid} <- lookup_registered_agent(state.job_id, agent_id) do
      pid_alive?(pid)
    else
      _ -> false
    end
  end

  defp pid_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  defp pid_alive?(pid) when is_pid(pid) do
    safe_remote_alive?(pid)
  end

  defp pid_alive?(_pid), do: false

  defp safe_remote_alive?(pid) do
    case :rpc.call(node(pid), Process, :alive?, [pid], 5_000) do
      true -> true
      _ -> false
    end
  rescue
    exception ->
      Logger.debug("remote pid liveness probe failed",
        pid: inspect(pid),
        error: Exception.message(exception)
      )

      false
  catch
    kind, reason ->
      Logger.debug("remote pid liveness probe failed",
        pid: inspect(pid),
        error: inspect({kind, reason})
      )

      false
  end

  defp lookup_registered_agent(job_id, agent_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _meta} | _] when is_pid(pid) -> {:ok, pid}
      _ -> :missing
    end
  rescue
    exception ->
      Logger.debug("agent registry lookup failed",
        job_id: job_id,
        agent_id: agent_id,
        error: Exception.message(exception)
      )

      :missing
  catch
    kind, reason ->
      Logger.debug("agent registry lookup failed",
        job_id: job_id,
        agent_id: agent_id,
        error: inspect({kind, reason})
      )

      :missing
  end

  defp schedule_health_check(interval_ms) do
    Process.send_after(self(), :health_check, interval_ms)
  end

  defp build_runtime_topology(manifest, scheduler_plan) do
    job_type = scheduler_plan["job_type"]
    placements = Map.get(scheduler_plan, "placements", [])

    if job_type in ["system", "sysbatch"] and placements != [] do
      build_system_runtime_topology(manifest, scheduler_plan, placements)
    else
      %{
        nodes: manifest.nodes,
        edges: manifest.edges,
        entrypoints: manifest.entrypoints,
        agent_ids: Enum.map(manifest.nodes, & &1.node_id),
        source_agent_ids: Map.new(manifest.nodes, &{&1.node_id, &1.node_id}),
        system_targets: [],
        agents_by_system_target: %{}
      }
    end
  end

  defp build_system_runtime_topology(manifest, scheduler_plan, placements) do
    source_nodes = Map.new(manifest.nodes, &{&1.node_id, &1})

    runtime_nodes =
      placements
      |> Enum.map(fn placement ->
        source_agent_id = placement["source_agent_id"] || placement["agent_id"]
        source_node = Map.fetch!(source_nodes, source_agent_id)
        target = placement["system_target"] || placement["node"]

        config =
          source_node.config
          |> Map.put("__mirror_neuron_source_node_id", source_agent_id)
          |> Map.put("__mirror_neuron_system_target", target)

        %{source_node | node_id: placement["agent_id"], config: config}
      end)

    system_targets =
      scheduler_plan
      |> Map.get("system_targets", [])
      |> case do
        [] ->
          placements
          |> Enum.map(&(&1["system_target"] || &1["node"]))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        targets ->
          targets
      end

    runtime_edges =
      for target <- system_targets,
          edge <- manifest.edges do
        %{
          edge
          | from_node: system_agent_id(edge.from_node, target),
            to_node: system_agent_id(edge.to_node, target)
        }
      end

    entrypoints =
      for target <- system_targets,
          entrypoint <- manifest.entrypoints do
        system_agent_id(entrypoint, target)
      end

    source_agent_ids =
      Map.new(placements, fn placement ->
        {placement["agent_id"], placement["source_agent_id"] || placement["agent_id"]}
      end)

    agents_by_system_target =
      placements
      |> Enum.group_by(&(&1["system_target"] || &1["node"]), & &1["agent_id"])
      |> Enum.reject(fn {target, _agents} -> is_nil(target) end)
      |> Map.new()

    %{
      nodes: runtime_nodes,
      edges: runtime_edges,
      entrypoints: entrypoints,
      agent_ids: Enum.map(runtime_nodes, & &1.node_id),
      source_agent_ids: source_agent_ids,
      system_targets: system_targets,
      agents_by_system_target: agents_by_system_target
    }
  end

  defp compatible_runtime_topology?(state, target_manifest, scheduler_plan) do
    topology = build_runtime_topology(target_manifest, scheduler_plan)
    MapSet.new(topology.agent_ids) == MapSet.new(state.agent_ids)
  end

  defp put_deployment_target(state, target_manifest, scheduler_plan, deployment_context) do
    topology = build_runtime_topology(target_manifest, scheduler_plan)

    %{
      state
      | manifest: target_manifest,
        runtime_nodes: topology.nodes,
        runtime_edges: topology.edges,
        runtime_entrypoints: topology.entrypoints,
        agent_ids: topology.agent_ids,
        source_agent_ids: topology.source_agent_ids,
        system_targets: topology.system_targets,
        agents_by_system_target: topology.agents_by_system_target,
        nodes_by_id: Map.new(topology.nodes, &{&1.node_id, &1}),
        outbound_edges_by_node: Enum.group_by(topology.edges, & &1.from_node),
        inbound_edges_by_node: Enum.group_by(topology.edges, & &1.to_node),
        downstream_by_node: build_downstream_index(topology.edges),
        workflow_state:
          WorkflowLedger.new(target_manifest, topology.nodes, %{
            "workflow_state" => state.workflow_state
          }),
        deployment_context: stringify_map(deployment_context)
    }
    |> put_scheduler_plan(scheduler_plan)
  end

  defp put_runtime_scheduler_plan(state, scheduler_plan) do
    topology = build_runtime_topology(state.manifest, scheduler_plan)

    %{
      state
      | runtime_nodes: topology.nodes,
        runtime_edges: topology.edges,
        runtime_entrypoints: topology.entrypoints,
        agent_ids: topology.agent_ids,
        source_agent_ids: topology.source_agent_ids,
        system_targets: topology.system_targets,
        agents_by_system_target: topology.agents_by_system_target,
        nodes_by_id: Map.new(topology.nodes, &{&1.node_id, &1}),
        outbound_edges_by_node: Enum.group_by(topology.edges, & &1.from_node),
        inbound_edges_by_node: Enum.group_by(topology.edges, & &1.to_node),
        downstream_by_node: build_downstream_index(topology.edges),
        workflow_state:
          WorkflowLedger.new(state.manifest, topology.nodes, %{
            "workflow_state" => state.workflow_state
          })
    }
    |> put_scheduler_plan(scheduler_plan)
  end

  defp runtime_topology(state) do
    %{
      "nodes" =>
        Enum.map(state.runtime_nodes, fn node ->
          %{
            "node_id" => node.node_id,
            "source_node_id" => Map.get(state.source_agent_ids, node.node_id, node.node_id),
            "agent_type" => node.agent_type,
            "type" => node.type,
            "role" => node.role,
            "system_target" => get_in(node.config, ["__mirror_neuron_system_target"])
          }
        end),
      "edges" =>
        Enum.map(state.runtime_edges, fn edge ->
          %{
            "edge_id" => edge.edge_id,
            "from_node" => edge.from_node,
            "to_node" => edge.to_node,
            "message_type" => edge.message_type,
            "routing_mode" => edge.routing_mode,
            "conditions" => edge.conditions
          }
        end),
      "entrypoints" => state.runtime_entrypoints,
      "system_targets" => state.system_targets
    }
  end

  defp system_agent_id(agent_id, target_node), do: "#{agent_id}@#{target_node}"

  defp job_type(state), do: scheduler_plan(state)["job_type"] || "batch"

  defp restart_policy(state, agent_id) do
    LifecyclePolicy.restart_policy(
      state.manifest,
      job_type(state),
      effective_recovery_policy(state),
      Map.get(state.source_agent_ids, agent_id, agent_id)
    )
  end

  defp reschedule_policy(state, agent_id) do
    LifecyclePolicy.reschedule_policy(
      state.manifest,
      job_type(state),
      effective_recovery_policy(state),
      Map.get(state.source_agent_ids, agent_id, agent_id)
    )
  end

  defp job_restart_policy(state) do
    LifecyclePolicy.restart_policy(
      state.manifest,
      job_type(state),
      effective_recovery_policy(state)
    )
  end

  defp job_reschedule_policy(state) do
    LifecyclePolicy.reschedule_policy(
      state.manifest,
      job_type(state),
      effective_recovery_policy(state)
    )
  end

  defp deployment_context_from(opts, existing_job) do
    Keyword.get(opts, :deployment_context) ||
      (is_map(existing_job) && Map.get(existing_job, "deployment")) ||
      %{}
  end

  defp deployment_job_fields(state) do
    state.deployment_context || %{}
  end

  defp policy_state_from(nil), do: %{"agents" => %{}}

  defp policy_state_from(job) when is_map(job) do
    case Map.get(job, "policy_state") do
      policy_state when is_map(policy_state) ->
        Map.put_new(policy_state, "agents", %{})

      _ ->
        %{"agents" => %{}}
    end
  end

  defp policy_history(state, agent_id, kind) do
    get_in(state.policy_state, ["agents", agent_id, "#{kind}_history"]) || []
  end

  defp put_policy_history(state, agent_id, kind, history) do
    put_policy_agent_fields(state, agent_id, %{"#{kind}_history" => history})
  end

  defp put_policy_agent_fields(state, agent_id, fields) do
    agents = Map.get(state.policy_state, "agents", %{})
    existing = Map.get(agents, agent_id, %{})

    policy_state =
      state.policy_state
      |> Map.put("agents", Map.put(agents, agent_id, Map.merge(existing, fields)))
      |> Map.put("updated_at", Runtime.timestamp())

    %{state | policy_state: policy_state}
  end

  defp mark_policy_idle(state, agent_id) do
    state
    |> clear_policy_timer({:restart, agent_id})
    |> clear_policy_timer({:reschedule, agent_id})
    |> put_policy_agent_fields(agent_id, %{
      "next_action" => nil,
      "next_eligible_at" => nil,
      "exhausted_reason" => nil,
      "last_success_at" => Runtime.timestamp()
    })
  end

  defp pending_policy_action?(state, agent_id) do
    agent_state = get_in(state.policy_state, ["agents", agent_id]) || %{}
    not is_nil(Map.get(agent_state, "next_action"))
  end

  defp schedule_policy_timer(state, key, message, delay_ms) do
    state = clear_policy_timer(state, key)
    ref = Process.send_after(self(), message, max(delay_ms, 0))
    %{state | pending_policy_timers: Map.put(state.pending_policy_timers, key, ref)}
  end

  defp clear_policy_timer(state, key) do
    case Map.pop(state.pending_policy_timers, key) do
      {nil, _timers} ->
        state

      {ref, timers} ->
        Process.cancel_timer(ref)
        %{state | pending_policy_timers: timers}
    end
  end

  defp cancel_policy_timers(state) do
    Enum.each(state.pending_policy_timers, fn {_key, ref} -> Process.cancel_timer(ref) end)
    %{state | pending_policy_timers: %{}}
  end

  defp cancel_policy_timers_for(state, agent_ids) do
    Enum.reduce(agent_ids, state, fn agent_id, acc ->
      acc
      |> clear_policy_timer({:restart, agent_id})
      |> clear_policy_timer({:reschedule, agent_id})
    end)
  end

  defp completed_agents_from(nil), do: MapSet.new()

  defp completed_agents_from(job) when is_map(job) do
    job
    |> Map.get("result", %{})
    |> list_from_result("completed_agents")
    |> MapSet.new()
  end

  defp completed_system_targets_from(nil), do: MapSet.new()

  defp completed_system_targets_from(job) when is_map(job) do
    job
    |> Map.get("result", %{})
    |> list_from_result("completed_targets")
    |> MapSet.new()
  end

  defp list_from_result(result, key) when is_map(result) do
    result
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp list_from_result(_result, _key), do: []

  defp put_completed_agent(state, agent_id) do
    %{state | completed_agents: MapSet.put(state.completed_agents, agent_id)}
  end

  defp put_completed_system_target(state, nil), do: state

  defp put_completed_system_target(state, target) do
    %{state | completed_system_targets: MapSet.put(state.completed_system_targets, target)}
  end

  defp put_sysbatch_result(state, agent_id, target, result) do
    existing = if is_map(state.result), do: state.result, else: %{}
    target_key = target || agent_id

    target_results =
      existing
      |> Map.get("target_results", %{})
      |> Map.put(target_key, %{"agent_id" => agent_id, "output" => result})

    %{
      state
      | result:
          existing
          |> Map.put("completed_agents", MapSet.to_list(state.completed_agents))
          |> Map.put("completed_targets", MapSet.to_list(state.completed_system_targets))
          |> Map.put("target_results", target_results)
    }
  end

  defp sysbatch_result(state) do
    if is_map(state.result) do
      state.result
    else
      %{
        "completed_agents" => MapSet.to_list(state.completed_agents),
        "completed_targets" => MapSet.to_list(state.completed_system_targets),
        "target_results" => %{}
      }
    end
  end

  defp all_system_targets_completed?(state) do
    expected = MapSet.new(state.system_targets)
    expected != MapSet.new() and MapSet.subset?(expected, state.completed_system_targets)
  end

  defp agent_completed?(state, agent_id) do
    target = system_target_for_agent(state, agent_id)

    MapSet.member?(state.completed_agents, agent_id) or
      (job_type(state) == "sysbatch" and not is_nil(target) and
         MapSet.member?(state.completed_system_targets, target))
  end

  defp ignorable_missing_agent?(state, agent_id) do
    node = Map.get(state.nodes_by_id, agent_id)

    job_type(state) == "service" and
      Map.get(node || %{}, :agent_type) == "router" and
      Map.get(state.inbound_edges_by_node, agent_id, []) == []
  end

  defp system_target_for_agent(state, agent_id) do
    case Map.get(state.nodes_by_id, agent_id) do
      %{config: config} when is_map(config) -> Map.get(config, "__mirror_neuron_system_target")
      _ -> nil
    end
  end

  defp agents_for_system_target(_state, nil, fallback), do: fallback

  defp agents_for_system_target(state, target, fallback) do
    Map.get(state.agents_by_system_target, target, fallback)
  end

  defp build_downstream_index(edges) do
    direct = Enum.group_by(edges, & &1.from_node, & &1.to_node)

    direct
    |> Map.keys()
    |> Enum.into(%{}, fn node_id ->
      {node_id, downstream_closure(node_id, direct, MapSet.new())}
    end)
  end

  defp downstream_closure(node_id, direct, visited) do
    direct
    |> Map.get(node_id, [])
    |> Enum.reject(&MapSet.member?(visited, &1))
    |> Enum.flat_map(fn child ->
      [child | downstream_closure(child, direct, MapSet.put(visited, child))]
    end)
    |> Enum.uniq()
  end

  defp do_wait_for_agents_ready(state, started_at, timeout_ms) do
    missing_agents = Enum.reject(state.agent_ids, &agent_ready?(state, &1))

    case missing_agents do
      [] ->
        :ok

      missing ->
        if System.monotonic_time(:millisecond) - started_at > timeout_ms do
          {:error, "timed out waiting for agents to register: #{Enum.join(missing, ", ")}"}
        else
          Process.sleep(25)
          do_wait_for_agents_ready(state, started_at, timeout_ms)
        end
    end
  end

  defp broadcast_agent_control(state, command) do
    Enum.each(state.agent_ids, fn agent_id ->
      case Horde.Registry.lookup(
             MirrorNeuron.DistributedRegistry,
             {:agent, state.job_id, agent_id}
           ) do
        [{pid, _}] -> GenServer.cast(pid, command)
        [] -> :ok
      end
    end)
  end

  defp terminate_agent_workers(state) do
    terminate_agent_workers(state, state.agent_ids)
  end

  defp terminate_agent_workers(state, agent_ids) do
    Enum.each(agent_ids, fn agent_id ->
      ServiceRegistry.deregister_agent(state.job_id, agent_id)

      case lookup_registered_agent(state.job_id, agent_id) do
        {:ok, pid} ->
          case safe_terminate_agent_child(pid) do
            :ok ->
              :ok

            {:error, :not_found} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "failed to terminate agent #{state.job_id}/#{agent_id}: #{inspect(reason)}"
              )

              safe_exit_agent(pid)
          end

        :missing ->
          :ok
      end
    end)
  end

  defp safe_terminate_agent_child(pid) do
    if node(pid) == Node.self() do
      DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.LocalAgentSupervisor, pid)
    else
      case :rpc.call(
             node(pid),
             DynamicSupervisor,
             :terminate_child,
             [MirrorNeuron.Runtime.LocalAgentSupervisor, pid],
             10_000
           ) do
        {:badrpc, reason} -> {:error, reason}
        other -> other
      end
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_exit_agent(pid) do
    if pid_alive?(pid) do
      Process.exit(pid, :kill)
    end

    :ok
  rescue
    exception ->
      Logger.debug("failed to force-exit agent process",
        pid: inspect(pid),
        error: Exception.message(exception)
      )

      :ok
  catch
    kind, reason ->
      Logger.debug("failed to force-exit agent process",
        pid: inspect(pid),
        error: inspect({kind, reason})
      )

      :ok
  end

  defp finalize_job(state, status, result, event_type, event_fields) do
    state = cancel_policy_timers(state)
    terminate_agent_workers(state)
    ServiceRegistry.deregister_job(state.job_id)
    {result, event_fields} = attach_failure_error(state, status, result, event_type, event_fields)
    {result, event_fields} = finalize_shared_storage(state, status, result, event_fields)

    next_state = %{
      state
      | status: status,
        result: result,
        workflow_state: WorkflowLedger.finish(state.workflow_state, status),
        pending_workflow_completion: nil
    }

    persist_job(next_state)
    cleanup_sandboxes(next_state)

    event =
      event_fields
      |> Map.put(:type, event_type)
      |> Map.put(:timestamp, Runtime.timestamp())

    EventBus.publish(state.job_id, event)
    next_state
  end

  defp finalize_shared_storage(state, status, result, event_fields) do
    manifest = MirrorNeuron.Manifest.to_map(state.manifest)

    case SharedStorage.finalize_terminal_job(state.job_id, manifest, status) do
      {:ok, []} ->
        {result, event_fields}

      {:ok, warnings} ->
        {put_finalization_warnings(result, warnings),
         Map.put(event_fields, :finalization_warnings, warnings)}

      {:error, warnings} ->
        {put_finalization_warnings(result, warnings),
         Map.put(event_fields, :finalization_warnings, warnings)}
    end
  end

  defp put_finalization_warnings(nil, warnings), do: %{"finalization_warnings" => warnings}

  defp put_finalization_warnings(result, warnings) when is_map(result) do
    Map.put(result, "finalization_warnings", warnings)
  end

  defp put_finalization_warnings(result, warnings) do
    %{"result" => result, "finalization_warnings" => warnings}
  end

  defp attach_failure_error(state, "failed", result, _event_type, event_fields) do
    error = failure_error(state, result, event_fields)
    desc = ErrorEnvelope.desc(error)

    event_fields =
      event_fields
      |> Map.put(:error, error)
      |> Map.put(:reason, desc)
      |> Map.put(:status_reason, desc)

    {failure_result(result, error, desc, event_fields), event_fields}
  end

  defp attach_failure_error(state, _status, result, :job_failed, event_fields) do
    attach_failure_error(state, "failed", result, :job_failed, event_fields)
  end

  defp attach_failure_error(_state, _status, result, _event_type, event_fields),
    do: {result, event_fields}

  defp failure_error(_state, result, event_fields) do
    reason =
      get_any(event_fields, [:error, "error", :reason, "reason", :status_reason, "status_reason"]) ||
        get_any(result, [:error, "error", :reason, "reason", :status_reason, "status_reason"]) ||
        "job failed"

    ErrorEnvelope.normalize(reason,
      component: "job_coordinator",
      step_id:
        get_any(event_fields, [:step_id, "step_id", :step, "step"]) ||
          get_any(result, [:step_id, "step_id", :step, "step"]),
      agent_id:
        get_any(event_fields, [:agent_id, "agent_id"]) || get_any(result, [:agent_id, "agent_id"]),
      node: to_string(Node.self())
    )
  end

  defp failure_result(result, error, desc, event_fields) when is_map(result) do
    result
    |> stringify_map()
    |> Map.put("error", error)
    |> Map.put("reason", desc)
    |> Map.put("status_reason", desc)
    |> Map.put_new("step_id", get_any(event_fields, [:step_id, "step_id", :step, "step"]))
    |> Map.put_new("agent_id", get_any(event_fields, [:agent_id, "agent_id"]))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp failure_result(result, error, desc, _event_fields) do
    %{
      "error" => error,
      "reason" => desc,
      "status_reason" => desc,
      "value" => stringify(result)
    }
  end

  defp pause_for_policy_review(state, agent_id, reason) do
    state = cancel_policy_timers(state)
    terminate_agent_workers(state)

    next_state =
      state
      |> put_policy_agent_fields(agent_id, %{
        "last_reason" => reason,
        "next_action" => nil,
        "next_eligible_at" => nil,
        "exhausted_reason" => reason,
        "requires_review" => true
      })
      |> Map.merge(%{
        status: "paused",
        result: %{"reason" => reason, "agent_id" => agent_id}
      })

    persist_job_with_recovery(next_state, reason)

    EventBus.publish(state.job_id, %{
      type: :job_paused_for_manual_restart,
      agent_id: agent_id,
      reason: reason,
      timestamp: Runtime.timestamp()
    })

    next_state
  end

  defp pause_for_profile_review(state, profile, agent_id, reason) do
    state = cancel_policy_timers(state)
    terminate_agent_workers(state)

    next_state = %{
      state
      | status: "paused",
        result: %{"reason" => reason, "agent_id" => agent_id}
    }

    persist_job_with_recovery(next_state, reason)

    EventBus.publish(state.job_id, %{
      type: :job_paused_for_manual_restart,
      agent_id: agent_id,
      execution_profile: profile,
      reason: reason,
      timestamp: Runtime.timestamp()
    })

    next_state
  end

  defp build_external_message(job_id, agent_id, message) do
    Message.normalize!(
      message,
      job_id: job_id,
      from: "external",
      to: agent_id,
      type: "command",
      class: "command",
      correlation_id: unique_id()
    )
  end

  defp persist_job(state) do
    lease = Keyword.get(state.opts, :job_lease)

    job_map =
      %{
        job_id: state.job_id,
        graph_id: state.manifest.graph_id,
        job_name: state.manifest.job_name,
        required_context_engine: Map.get(state.manifest, :required_context_engine, false),
        status: state.status,
        submitted_at: Map.get(state, :submitted_at, Runtime.timestamp()),
        updated_at: Runtime.timestamp(),
        root_agent_ids: state.manifest.entrypoints,
        placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
        job_type: scheduler_plan(state)["job_type"],
        scheduler: scheduler_plan(state),
        requested_recovery_policy: requested_recovery_policy(state),
        recovery_policy: effective_recovery_policy(state),
        reliability_degraded: reliability_degraded?(state),
        reliability: reliability_map(state),
        restart_policy: job_restart_policy(state),
        reschedule_policy: job_reschedule_policy(state),
        policy_state: state.policy_state,
        workflow_state: state.workflow_state,
        pending_workflow_completion: state.pending_workflow_completion,
        deployment: deployment_job_fields(state),
        result: state.result,
        topology: MirrorNeuron.Manifest.topology(state.manifest),
        runtime_topology: runtime_topology(state),
        manifest: MirrorNeuron.Manifest.to_map(state.manifest),
        manifest_ref: manifest_ref(state)
      }
      |> maybe_put_lease(lease)
      |> Map.merge(existing_recovery_fields(state.job_id))

    case RedisStore.persist_job(state.job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to persist job #{state.job_id}: #{inspect(reason)}")
    end
  end

  defp persist_job_with_recovery(state, reason) do
    recovery = %{
      "status" => "paused_for_review",
      "reason" => reason,
      "requires_review" => true,
      "can_resume" => true,
      "updated_at" => Runtime.timestamp()
    }

    job_map =
      %{
        job_id: state.job_id,
        graph_id: state.manifest.graph_id,
        job_name: state.manifest.job_name,
        required_context_engine: Map.get(state.manifest, :required_context_engine, false),
        status: "paused",
        submitted_at: Map.get(state, :submitted_at, Runtime.timestamp()),
        updated_at: Runtime.timestamp(),
        root_agent_ids: state.manifest.entrypoints,
        placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
        job_type: scheduler_plan(state)["job_type"],
        scheduler: scheduler_plan(state),
        requested_recovery_policy: requested_recovery_policy(state),
        recovery_policy: effective_recovery_policy(state),
        reliability_degraded: reliability_degraded?(state),
        result: state.result,
        topology: MirrorNeuron.Manifest.topology(state.manifest),
        runtime_topology: runtime_topology(state),
        manifest: MirrorNeuron.Manifest.to_map(state.manifest),
        manifest_ref: manifest_ref(state),
        recovery: recovery,
        recovery_status: "paused_for_review",
        recovery_reason: reason,
        recovery_requires_review: true,
        reliability: reliability_map(state),
        restart_policy: job_restart_policy(state),
        reschedule_policy: job_reschedule_policy(state),
        policy_state: state.policy_state,
        workflow_state: state.workflow_state,
        pending_workflow_completion: state.pending_workflow_completion,
        deployment: deployment_job_fields(state)
      }
      |> maybe_put_lease(Keyword.get(state.opts, :job_lease))

    case RedisStore.persist_job(state.job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist profile recovery state for #{state.job_id}: #{inspect(persist_reason)}"
        )
    end
  end

  defp publish_workflow_events(_state, []), do: :ok

  defp publish_workflow_events(state, events) when is_list(events) do
    Enum.each(events, fn
      %{type: _type} = event ->
        EventBus.publish(state.job_id, event)

      %{"type" => _type} = event ->
        EventBus.publish(state.job_id, event)

      _event ->
        :ok
    end)
  end

  defp publish_workflow_events(_state, _events), do: :ok

  defp cleanup_sandboxes(state) do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.each(fn node ->
      cleanup_sandbox_on_node(node, OpenShellJobSandbox, state.job_id, "OpenShell")
      cleanup_sandbox_on_node(node, DockerJobSandbox, state.job_id, "DockerWorker")
    end)
  end

  defp cleanup_sandbox_on_node(node, module, job_id, label) do
    case safe_cleanup_sandbox_on_node(node, module, job_id) do
      :ok ->
        :ok

      {:badrpc, reason} ->
        Logger.warning(
          "failed to clean up #{label} sandbox for #{job_id} on #{node}: #{inspect(reason)}"
        )

      _other ->
        :ok
    end
  end

  defp safe_cleanup_sandbox_on_node(node, module, job_id) do
    :rpc.call(node, module, :cleanup_job_local, [job_id], 15_000)
  rescue
    exception -> {:badrpc, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:badrpc, {kind, reason}}
  end

  defp existing_recovery_fields(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} ->
        job
        |> Map.take([
          "recovery",
          "recovery_status",
          "recovery_reason",
          "recovery_requires_review",
          "restore_provenance"
        ])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp agent_runtime_context(state) do
    lease = Keyword.get(state.opts, :job_lease)
    bundle_paths = runtime_bundle_paths(state)

    %{
      bundle_root: bundle_paths.bundle_root,
      manifest_path: bundle_paths.manifest_path,
      payloads_path: bundle_paths.payloads_path,
      artifact_refs:
        MirrorNeuron.Artifacts.BlobRef.collect(MirrorNeuron.Manifest.to_map(state.manifest)),
      manifest_ref: manifest_ref(state),
      manifest: MirrorNeuron.Manifest.to_map(state.manifest),
      graph_id: state.manifest.graph_id,
      job_name: state.manifest.job_name,
      required_context_engine: Map.get(state.manifest, :required_context_engine, false),
      entrypoints: state.runtime_entrypoints,
      placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
      job_type: scheduler_plan(state)["job_type"],
      scheduler: scheduler_plan(state),
      requested_recovery_policy: requested_recovery_policy(state),
      recovery_policy: effective_recovery_policy(state),
      reliability: reliability_map(state),
      restart_policy: job_restart_policy(state),
      reschedule_policy: job_reschedule_policy(state),
      policy_state: state.policy_state,
      deployment: deployment_job_fields(state),
      submitted_at: state.submitted_at,
      runtime_env: MirrorNeuron.Runtime.RedisEnvironment.agent_env(),
      manifest_version: state.manifest.manifest_version,
      lease_epoch: lease && lease["epoch"],
      lease_owner: lease && lease["owner_id"],
      workflow_run_id: WorkflowLedger.run_id(state.workflow_state),
      workflow_agent_steps: WorkflowLedger.agent_to_step(state.workflow_state),
      backpressure_by_agent:
        Map.new(state.runtime_nodes, fn node ->
          {node.node_id, Backpressure.config(node) |> Map.to_list()}
        end),
      execution_profiles:
        Map.new(state.runtime_nodes, fn node ->
          {node.node_id, Profile.profile_name(node.config)}
        end)
    }
  end

  defp manifest_ref(state) do
    Keyword.get(state.opts, :bundle_ref) ||
      Runtime.bundle_ref(state.manifest, state.bundle)
  end

  defp runtime_bundle_root(state), do: runtime_bundle_paths(state).bundle_root

  defp runtime_bundle_paths(state) do
    case shared_bundle_cache_path(manifest_ref(state)) do
      nil ->
        %{
          bundle_root: state.bundle && state.bundle.root_path,
          manifest_path: state.bundle && state.bundle.manifest_path,
          payloads_path: state.bundle && state.bundle.payloads_path
        }

      cache_path ->
        %{
          bundle_root: cache_path,
          manifest_path: Path.join(cache_path, "manifest.json"),
          payloads_path: Path.join(cache_path, "payloads")
        }
    end
  end

  defp shared_bundle_cache_path(manifest_ref) when is_map(manifest_ref) do
    storage = Map.get(manifest_ref, "bundle_storage") || Map.get(manifest_ref, :bundle_storage)
    cache_path = Map.get(manifest_ref, "cache_path") || Map.get(manifest_ref, :cache_path)

    if storage in ["shared_fs", "shared_fs_cas"] and is_binary(cache_path) and cache_path != "" do
      cache_path
    end
  end

  defp shared_bundle_cache_path(_manifest_ref), do: nil

  defp scheduler_plan(state) do
    scheduler_plan_from(state.manifest, state.opts)
  end

  defp scheduler_plan_from(manifest, opts) do
    Keyword.get(opts, :scheduler_plan) || default_scheduler_plan(manifest)
  end

  defp default_scheduler_plan(manifest) do
    %{
      "status" => "unknown",
      "job_type" => manifest.type || "batch",
      "strategy" => "unknown",
      "placements" => []
    }
  end

  defp put_scheduler_plan(state, scheduler_plan) do
    %{state | opts: Keyword.put(state.opts, :scheduler_plan, scheduler_plan)}
  end

  defp normalize_agent_ids(agent_ids, state) do
    valid = MapSet.new(state.agent_ids)

    agent_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&MapSet.member?(valid, &1))
    |> Enum.uniq()
  end

  defp maybe_put_lease(map, nil), do: map

  defp maybe_put_lease(map, lease) do
    map
    |> Map.put(:lease, lease)
    |> Map.put(:lease_epoch, lease["epoch"])
    |> Map.put(:lease_owner, lease["owner_id"])
  end

  defp reliability_from(opts, existing_job) do
    requested =
      Keyword.get(opts, :requested_recovery_policy) ||
        (is_map(existing_job) && existing_job["requested_recovery_policy"]) ||
        "auto"

    effective =
      Keyword.get(opts, :recovery_policy) ||
        (is_map(existing_job) && existing_job["recovery_policy"]) ||
        if(requested == "auto", do: "local_restart", else: requested)

    defaults = %{
      "mode" => "single_node",
      "requested_recovery_policy" => requested,
      "effective_recovery_policy" => effective,
      "degraded" => false,
      "reason" => "legacy job without reliability metadata",
      "observed_nodes" => [to_string(Node.self())],
      "observed_at" => Runtime.timestamp()
    }

    opts
    |> Keyword.get(
      :reliability,
      if(is_map(existing_job), do: existing_job["reliability"], else: %{})
    )
    |> normalize_reliability()
    |> then(&Map.merge(defaults, &1))
  end

  defp effective_recovery_policy(state) do
    get_in(state.reliability, ["effective_recovery_policy"]) ||
      Keyword.get(state.opts, :recovery_policy) ||
      Map.get(state.manifest.policies, "recovery_mode", "local_restart")
  end

  defp requested_recovery_policy(state) do
    get_in(state.reliability, ["requested_recovery_policy"]) ||
      Keyword.get(state.opts, :requested_recovery_policy) ||
      Map.get(state.manifest.policies, "recovery_mode", "auto")
  end

  defp reliability_degraded?(state), do: get_in(state.reliability, ["degraded"]) == true

  defp reliability_map(state) do
    state.reliability
    |> Map.take([
      "mode",
      "effective_recovery_policy",
      "degraded",
      "reason",
      "observed_nodes",
      "observed_at"
    ])
    |> Map.put("restart_policy", job_restart_policy(state))
    |> Map.put("reschedule_policy", job_reschedule_policy(state))
    |> Map.put("policy_state", state.policy_state)
  end

  defp normalize_reliability(reliability) when is_map(reliability), do: reliability
  defp normalize_reliability(_reliability), do: %{}

  defp pending_workflow_completion_from(%{"pending_workflow_completion" => pending})
       when is_map(pending),
       do: pending

  defp pending_workflow_completion_from(_existing_job), do: nil

  defp node_backpressure_opts(state, agent_id) do
    state.nodes_by_id
    |> Map.get(agent_id, %{})
    |> Backpressure.config()
    |> Map.to_list()
  end

  defp unique_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      value = Map.get(map, key)
      if value in [nil, ""], do: nil, else: value
    end)
  end

  defp get_any(_value, _keys), do: nil

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
