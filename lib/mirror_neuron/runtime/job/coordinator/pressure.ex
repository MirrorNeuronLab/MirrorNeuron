defmodule MirrorNeuron.Runtime.JobCoordinator.Pressure do
  @moduledoc "Queue pressure observations and admission of external input."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Backpressure
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.LiveInput

  def refresh_pressure(state) do
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

  def pressure_event_changed?(previous, pressure) when is_map(previous) and is_map(pressure) do
    Backpressure.pressured?(pressure) and
      (Map.get(previous, "status") != Map.get(pressure, "status") or
         Map.get(previous, "queue_depth") != Map.get(pressure, "queue_depth"))
  end

  def pressure_event_changed?(_previous, pressure) do
    Backpressure.pressured?(pressure)
  end

  defp agent_pressure_snapshot(state, agent_id) do
    with {:ok, pid} <- Processes.lookup_registered_agent(state.job_id, agent_id),
         node when is_map(node) <- Map.get(state.nodes_by_id, agent_id) do
      case MirrorNeuron.Runtime.DeliveryChannels.depth(state.job_id, agent_id) do
        {:ok, depth} ->
          Backpressure.snapshot(agent_id, node, depth, [], Map.get(state.pressure, agent_id))
          |> Map.put("mailbox_depth", Backpressure.process_queue_depth(pid))

        {:error, _} ->
          Backpressure.snapshot(agent_id, node, Backpressure.config(node).max_queue_depth)
          |> Map.put("unavailable", true)
      end
    else
      _ -> nil
    end
  end

  def external_input_pressure(state, agent_id, message) do
    impacted_agents =
      LiveInput.pressure_targets(
        state.manifest.contract,
        agent_id,
        message,
        Map.get(state.downstream_by_node, agent_id, [])
      )

    pressure =
      if LiveInput.command?(state.manifest.contract, agent_id, message) do
        node = Map.fetch!(state.nodes_by_id, agent_id)

        case MirrorNeuron.Runtime.DeliveryChannels.depth(state.job_id, agent_id, :command) do
          {:ok, depth} ->
            %{agent_id => Backpressure.snapshot(agent_id, node, depth)}

          _ ->
            %{
              agent_id =>
                Backpressure.snapshot(agent_id, node, Backpressure.config(node).max_queue_depth)
            }
        end
      else
        state.pressure
      end

    pressure
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

  def pressure_summary(state) do
    %{
      "job_id" => state.job_id,
      "pressured" =>
        state.pressure
        |> Enum.filter(fn {_id, snapshot} -> Backpressure.pressured?(snapshot) end)
        |> Enum.map(fn {id, snapshot} -> Map.put(snapshot, "agent_id", id) end),
      "agents" => state.pressure
    }
  end

  def node_backpressure_opts(state, agent_id) do
    state.nodes_by_id
    |> Map.get(agent_id, %{})
    |> Backpressure.config()
    |> Map.to_list()
  end
end
