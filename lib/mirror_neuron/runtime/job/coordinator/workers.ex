defmodule MirrorNeuron.Runtime.JobCoordinator.Workers do
  @moduledoc "Starts and recovers workers on their planned execution nodes."

  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AgentWorker
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Context
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.Services
  alias MirrorNeuron.Runtime.JobCoordinator.Targets
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.LifecyclePolicy
  alias MirrorNeuron.Scheduler

  def start_agents(state), do: start_agents(state, [])

  def start_agents(state, excluded_nodes) do
    case do_start_agents(state) do
      :ok ->
        {:ok, state}

      {:error, {:target_node_unavailable, target_node, agent_id}} ->
        if target_node in excluded_nodes do
          {:error,
           "failed to start agent #{agent_id}: {:target_node_unavailable, #{inspect(target_node)}}",
           state}
        else
          Processes.terminate_agent_workers(state)
          _ = Processes.wait_for_agents_stopped(state, 5_000)

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
        next_state = Topology.put_runtime_scheduler_plan(state, scheduler_plan)

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

  def recover_agents(state, agent_ids, recovery_snapshot \\ nil) do
    Enum.reduce_while(agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      if Targets.agent_completed?(acc_state, agent_id) do
        {:cont, {:ok, acc_state}}
      else
        case recover_agent(acc_state, agent_id, recovery_snapshot) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
        end
      end
    end)
  end

  def deploy_agents_now(state, agent_ids) do
    Enum.reduce_while(agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      case start_agent(acc_state, agent_id, nil) do
        {:ok, _pid} ->
          with :ok <- Processes.wait_for_agent_ready(acc_state, agent_id, 30_000),
               :ok <- Services.register_agent_services(acc_state, agent_id) do
            {:cont, {:ok, Policy.mark_policy_idle(acc_state, agent_id)}}
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

  def recover_agent(state, agent_id, recovery_snapshot \\ nil) do
    attempt =
      max(
        LifecyclePolicy.active_attempt_count(
          Policy.restart_policy(state, agent_id),
          Policy.policy_history(state, agent_id, "restart")
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
        finalize_agent_recovery(state, agent_id, attempt)

      {:error, {:already_started, _pid}} ->
        finalize_agent_recovery(state, agent_id, attempt)

      {:error, reason} ->
        {:error, "failed to recover agent #{agent_id}: #{inspect(reason)}", state}
    end
  end

  defp finalize_agent_recovery(state, agent_id, attempt) do
    case Processes.wait_for_agent_ready(state, agent_id, 30_000) do
      :ok ->
        case Services.register_agent_services(state, agent_id) do
          :ok ->
            EventBus.publish(state.job_id, %{
              type: :agent_recovered,
              agent_id: agent_id,
              attempt: attempt,
              timestamp: Runtime.timestamp()
            })

            {:ok, Policy.mark_policy_idle(state, agent_id)}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp start_agent(state, agent_id, recovery_snapshot \\ nil, retry_count \\ 0) do
    node =
      state.nodes_by_id
      |> Map.fetch!(agent_id)
      |> apply_execution_profile()

    execution_profile = Profile.profile_name(node.config)

    spec =
      AgentWorker.child_spec(
        {state.job_id, node, Map.get(state.outbound_edges_by_node, agent_id, []),
         Map.get(state.inbound_edges_by_node, agent_id, []), self(),
         Context.agent_runtime_context(state, node), recovery_snapshot}
      )
      |> Map.put(:mirror_neuron_delivery_version, state.delivery_version)
      |> Map.put(:mirror_neuron_execution_profile, execution_profile)
      |> Map.put(
        :mirror_neuron_target_node,
        Scheduler.target_node(Topology.scheduler_plan(state), agent_id)
      )

    case start_agent_on_target(
           spec,
           Scheduler.target_node(Topology.scheduler_plan(state), agent_id)
         ) do
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
        version = Map.get(spec, :mirror_neuron_delivery_version, 2)

        supported =
          :rpc.call(
            target_node,
            MirrorNeuron.Runtime.DeliveryChannels,
            :supported_versions,
            [],
            5_000
          )

        if is_list(supported) and version in supported do
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
        else
          {:error, {:unsupported_delivery_version, version, target_node}}
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
end
