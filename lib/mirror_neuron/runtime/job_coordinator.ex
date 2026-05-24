defmodule MirrorNeuron.Runtime.JobCoordinator do
  use GenServer
  require Logger

  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Runtime.{AgentWorker, Backpressure, EventBus, Naming}
  alias MirrorNeuron.Sandbox.JobSandbox

  @default_health_check_interval_ms 2_000
  @default_max_agent_restart_attempts 3

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
      agent_restart_attempts: %{},
      max_agent_restart_attempts:
        Map.get(
          manifest.policies,
          "max_agent_restart_attempts",
          @default_max_agent_restart_attempts
        ),
      health_check_interval_ms:
        Application.get_env(
          :mirror_neuron,
          :job_health_check_interval_ms,
          @default_health_check_interval_ms
        ),
      reliability: reliability_from(opts, existing_job)
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
         {:ok, next_state} <- recover_missing_agents(state) do
      persist_job(next_state)

      EventBus.publish(state.job_id, %{
        type: :job_recovered,
        status: next_state.status,
        timestamp: Runtime.timestamp()
      })

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

    with :ok <- start_agents(state),
         :ok <- wait_for_agents_ready(state),
         :ok <- seed_entrypoints(state) do
      next_state = %{state | status: "running"}
      persist_job(next_state)
      EventBus.publish(state.job_id, %{type: :job_running, timestamp: Runtime.timestamp()})
      schedule_health_check(next_state.health_check_interval_ms)
      {:noreply, next_state}
    else
      {:error, {:execution_profile_unavailable, profile, agent_id}} ->
        paused_state =
          pause_for_profile_review(
            state,
            profile,
            agent_id,
            "execution profile #{profile} has no eligible runtime nodes"
          )

        {:stop, :normal, paused_state}

      {:error, reason} ->
        failed_state =
          finalize_job(state, "failed", %{error: reason}, :job_failed, %{reason: reason})

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  @impl true
  def handle_call(:pause, _from, %{status: "running"} = state) do
    broadcast_agent_control(state, :pause)
    next_state = %{state | status: "paused"}
    persist_job(next_state)
    EventBus.publish(state.job_id, %{type: :job_paused, timestamp: Runtime.timestamp()})
    {:reply, {:ok, "paused"}, next_state}
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, "job is not running"}, state}

  @impl true
  def handle_call(:resume, _from, %{status: "paused"} = state) do
    broadcast_agent_control(state, :resume)
    next_state = %{state | status: "running"}
    persist_job(next_state)
    EventBus.publish(state.job_id, %{type: :job_resumed, timestamp: Runtime.timestamp()})
    {:reply, {:ok, "resumed"}, next_state}
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
      next_state = put_scheduler_plan(state, scheduler_plan)

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
  def handle_info({:agent_event, agent_id, event_type, payload}, state) do
    EventBus.publish(state.job_id, %{
      type: event_type,
      agent_id: agent_id,
      payload: payload,
      timestamp: Runtime.timestamp()
    })

    {:noreply, state}
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

  def handle_info({:agent_completed_job, agent_id, result}, state) do
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

  def handle_info({:agent_failed, agent_id, reason}, state) do
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

  def handle_info(:health_check, %{status: status} = state)
      when status in ["running", "paused"] do
    state = refresh_pressure(state)

    case recover_missing_agents(state) do
      {:ok, next_state} ->
        schedule_health_check(next_state.health_check_interval_ms)
        {:noreply, next_state}

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

    case restart_agents(state, [agent_id], "service agent completed") do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, reason, next_state} ->
        EventBus.publish(state.job_id, %{
          type: :service_agent_restart_failed,
          agent_id: agent_id,
          reason: reason,
          timestamp: Runtime.timestamp()
        })

        schedule_health_check(next_state.health_check_interval_ms)
        {:noreply, next_state}
    end
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

    case restart_agents(state, agent_ids, "system target completed") do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, reason, next_state} ->
        EventBus.publish(state.job_id, %{
          type: :system_target_restart_failed,
          agent_id: agent_id,
          system_target: target,
          reason: reason,
          timestamp: Runtime.timestamp()
        })

        schedule_health_check(next_state.health_check_interval_ms)
        {:noreply, next_state}
    end
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

  defp restart_failed_agent(state, agent_id, reason) do
    EventBus.publish(state.job_id, %{
      type: :agent_restart_scheduled,
      agent_id: agent_id,
      reason: inspect(reason),
      job_type: job_type(state),
      timestamp: Runtime.timestamp()
    })

    case restart_agents(state, [agent_id], inspect(reason)) do
      {:ok, next_state} ->
        {:ok, next_state}

      {:error, failed_reason, next_state} ->
        if job_type(state) in ["service", "system"] do
          EventBus.publish(state.job_id, %{
            type: :agent_restart_deferred,
            agent_id: agent_id,
            reason: failed_reason,
            timestamp: Runtime.timestamp()
          })

          schedule_health_check(next_state.health_check_interval_ms)
          {:ok, next_state}
        else
          {:error, failed_reason, next_state}
        end
    end
  end

  defp restart_agents(state, agent_ids, reason) do
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

  defp start_agents(state) do
    Enum.reduce_while(state.runtime_nodes, :ok, fn node, :ok ->
      case start_agent(state, node.node_id) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, {:already_started, _pid}} ->
          {:cont, :ok}

        {:error, {:no_eligible_execution_profile_nodes, profile}} ->
          {:halt, {:error, {:execution_profile_unavailable, profile, node.node_id}}}

        {:error, reason} ->
          {:halt, {:error, "failed to start agent #{node.node_id}: #{inspect(reason)}"}}
      end
    end)
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
    with [{pid, _meta}] <-
           Horde.Registry.lookup(
             MirrorNeuron.DistributedRegistry,
             {:agent, state.job_id, agent_id}
           ) do
      node = Map.fetch!(state.nodes_by_id, agent_id)
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

  defp recover_agent(state, agent_id) do
    attempts = Map.get(state.agent_restart_attempts, agent_id, 0)

    if restart_attempts_exhausted?(state, attempts) do
      {:error,
       "agent #{agent_id} exceeded restart attempts (#{state.max_agent_restart_attempts})", state}
    else
      recovery_snapshot =
        case RedisStore.fetch_agent(state.job_id, agent_id) do
          {:ok, snapshot} -> snapshot
          _ -> nil
        end

      EventBus.publish(state.job_id, %{
        type: :agent_recovery_started,
        agent_id: agent_id,
        attempt: attempts + 1,
        timestamp: Runtime.timestamp()
      })

      case start_agent(state, agent_id, recovery_snapshot) do
        {:ok, _pid} ->
          wait_result = wait_for_agent_ready(state, agent_id, 30_000)

          case wait_result do
            :ok ->
              EventBus.publish(state.job_id, %{
                type: :agent_recovered,
                agent_id: agent_id,
                attempt: attempts + 1,
                timestamp: Runtime.timestamp()
              })

              {:ok, put_in(state.agent_restart_attempts[agent_id], attempts + 1)}

            {:error, reason} ->
              {:error, reason, state}
          end

        {:error, {:already_started, _pid}} ->
          {:ok, state}

        {:error, reason} ->
          {:error, "failed to recover agent #{agent_id}: #{inspect(reason)}", state}
      end
    end
  end

  defp restart_attempts_exhausted?(state, attempts) do
    if job_type(state) in ["service", "system"] do
      false
    else
      attempts >= state.max_agent_restart_attempts
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

    case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.AgentSupervisor, spec) do
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
    case Horde.Registry.lookup(
           MirrorNeuron.DistributedRegistry,
           {:agent, state.job_id, agent_id}
         ) do
      [{pid, _meta}] -> Process.alive?(pid)
      _ -> false
    end
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
    missing_agents =
      Enum.reject(state.agent_ids, fn agent_id ->
        match?(
          [{_pid, _meta}],
          Horde.Registry.lookup(
            MirrorNeuron.DistributedRegistry,
            {:agent, state.job_id, agent_id}
          )
        )
      end)

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
      case Horde.Registry.lookup(
             MirrorNeuron.DistributedRegistry,
             {:agent, state.job_id, agent_id}
           ) do
        [{pid, _}] ->
          case Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.AgentSupervisor, pid) do
            :ok ->
              :ok

            {:error, :not_found} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "failed to terminate agent #{state.job_id}/#{agent_id}: #{inspect(reason)}"
              )

              if Process.alive?(pid), do: Process.exit(pid, :kill)
          end

        [] ->
          :ok
      end
    end)
  end

  defp finalize_job(state, status, result, event_type, event_fields) do
    terminate_agent_workers(state)

    next_state = %{state | status: status, result: result}
    persist_job(next_state)
    cleanup_sandboxes(next_state)

    event =
      event_fields
      |> Map.put(:type, event_type)
      |> Map.put(:timestamp, Runtime.timestamp())

    EventBus.publish(state.job_id, event)
    next_state
  end

  defp pause_for_profile_review(state, profile, agent_id, reason) do
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
        reliability: reliability_map(state)
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

  defp cleanup_sandboxes(state) do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.each(fn node ->
      case :rpc.call(node, JobSandbox, :cleanup_job_local, [state.job_id], 15_000) do
        :ok ->
          :ok

        {:badrpc, reason} ->
          Logger.warning(
            "failed to clean up shared sandbox for #{state.job_id} on #{node}: #{inspect(reason)}"
          )

        _other ->
          :ok
      end
    end)
  end

  defp existing_recovery_fields(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} ->
        job
        |> Map.take([
          "recovery",
          "recovery_status",
          "recovery_reason",
          "recovery_requires_review"
        ])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp agent_runtime_context(state) do
    lease = Keyword.get(state.opts, :job_lease)

    %{
      bundle_root: state.bundle && state.bundle.root_path,
      manifest_path: state.bundle && state.bundle.manifest_path,
      payloads_path: state.bundle && state.bundle.payloads_path,
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
      submitted_at: state.submitted_at,
      manifest_version: state.manifest.manifest_version,
      lease_epoch: lease && lease["epoch"],
      lease_owner: lease && lease["owner_id"],
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
      %{
        graph_id: state.manifest.graph_id,
        manifest_version: state.manifest.manifest_version,
        manifest_path: state.bundle && state.bundle.manifest_path,
        job_path: state.bundle && state.bundle.root_path
      }
  end

  defp scheduler_plan(state) do
    scheduler_plan_from(state.manifest, state.opts)
  end

  defp scheduler_plan_from(manifest, opts) do
    Keyword.get(opts, :scheduler_plan) || default_scheduler_plan(manifest)
  end

  defp default_scheduler_plan(manifest) do
    %{
      "status" => "unknown",
      "job_type" => if(manifest.daemon, do: "service", else: "batch"),
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
    Map.take(state.reliability, [
      "mode",
      "effective_recovery_policy",
      "degraded",
      "reason",
      "observed_nodes",
      "observed_at"
    ])
  end

  defp normalize_reliability(reliability) when is_map(reliability), do: reliability
  defp normalize_reliability(_reliability), do: %{}

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
end
