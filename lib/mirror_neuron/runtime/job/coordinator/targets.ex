defmodule MirrorNeuron.Runtime.JobCoordinator.Targets do
  @moduledoc "Service, system and sysbatch completion ownership and aggregate results."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Finalization
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.Recovery
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Topology

  def restart_service_agent(state, agent_id, result) do
    EventBus.publish(state.job_id, %{
      type: :service_agent_completed,
      agent_id: agent_id,
      result: result,
      timestamp: Runtime.timestamp()
    })

    Processes.terminate_agent_workers(state, [agent_id])

    {:ok, next_state} =
      Recovery.schedule_agent_restarts(state, [agent_id], "service agent completed")

    {:noreply, next_state}
  end

  def restart_system_target(state, agent_id, result) do
    target = system_target_for_agent(state, agent_id)
    agent_ids = agents_for_system_target(state, target, [agent_id])

    EventBus.publish(state.job_id, %{
      type: :system_target_completed,
      agent_id: agent_id,
      system_target: target,
      result: result,
      timestamp: Runtime.timestamp()
    })

    Processes.terminate_agent_workers(state, agent_ids)

    {:ok, next_state} =
      Recovery.schedule_agent_restarts(state, agent_ids, "system target completed")

    {:noreply, next_state}
  end

  def complete_sysbatch_target(state, agent_id, result) do
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

    Processes.terminate_agent_workers(next_state, agent_ids)

    if all_system_targets_completed?(next_state) do
      completed_state =
        Finalization.finalize_job(
          next_state,
          "completed",
          sysbatch_result(next_state),
          :job_completed,
          %{agent_id: agent_id, result: sysbatch_result(next_state)}
        )

      {:stop, :normal, completed_state}
    else
      Snapshots.persist_job(next_state)
      {:noreply, next_state}
    end
  end

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

  def agent_completed?(state, agent_id) do
    target = system_target_for_agent(state, agent_id)

    MapSet.member?(state.completed_agents, agent_id) or
      (Topology.job_type(state) == "sysbatch" and not is_nil(target) and
         MapSet.member?(state.completed_system_targets, target))
  end

  def ignorable_missing_agent?(state, agent_id) do
    node = Map.get(state.nodes_by_id, agent_id)

    Topology.job_type(state) == "service" and
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
end
