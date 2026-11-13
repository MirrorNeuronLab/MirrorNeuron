defmodule MirrorNeuron.Runtime.ServiceEventWorkflow do
  @moduledoc "Classifies native event-only services separately from finite workflow DAGs."

  def event_only?(%{type: "service", flow: flow}, nodes, definitions)
      when is_map(flow) and definitions != [] do
    callbacks =
      nodes
      |> Enum.filter(fn node ->
        get_in(node, [:config, "block_event", "version"]) == "mn.block_events/v1" and
          Map.get(node, :agent_type) == "executor"
      end)
      |> MapSet.new(& &1.node_id)

    Map.get(flow, "mode", "static_dag") == "static_dag" and
      Map.get(flow, "dynamic", %{}) in [%{}, %{"enabled" => false}] and
      Map.get(flow, "child_workflows", %{}) == %{} and
      Enum.all?(definitions, fn
        %{"agent_ids" => [agent_id]} -> MapSet.member?(callbacks, agent_id)
        _ -> false
      end)
  end

  def event_only?(_manifest, _nodes, _definitions), do: false
end
