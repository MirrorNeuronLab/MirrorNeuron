defmodule MirrorNeuron.Scheduler.Placement.SystemWorkloads do
  @moduledoc "Places a complete system workload on every eligible node."

  alias MirrorNeuron.Scheduler.Placement.Allocation
  alias MirrorNeuron.Scheduler.Placement.Eligibility
  alias MirrorNeuron.Scheduler.Placement.Group
  alias MirrorNeuron.Scheduler.Placement.Scoring
  alias MirrorNeuron.Scheduler.Placement.Usage

  def place_system_demands(
        demands,
        nodes,
        usage,
        strategy,
        only_agent_ids,
        service_instances,
        blob_refs
      ) do
    only_agent_ids = normalize_agent_id_filter(only_agent_ids)

    eligible =
      nodes
      |> Enum.filter(&Eligibility.schedulable_node?/1)
      |> Enum.reduce([], fn node, acc ->
        case system_node_plan(
               node,
               demands,
               Usage.usage_for_node(usage, node["name"]),
               service_instances
             ) do
          {:ok, group_plan} ->
            score =
              Scoring.score_node_detail(
                node,
                Usage.usage_for_node(usage, node["name"]),
                group_plan["resources"],
                strategy,
                blob_refs,
                demands
              )

            [{node, group_plan, score} | acc]

          :error ->
            acc
        end
      end)
      |> Enum.reverse()

    case eligible do
      [] ->
        {:error, no_system_candidate_reason(demands, nodes, usage, service_instances)}

      eligible ->
        {placements, placed_demands, usage} =
          Enum.reduce(eligible, {[], [], usage}, fn {node, group_plan, score},
                                                    {placement_acc, demand_acc, usage_acc} ->
            target_node = node["name"]

            target_placements =
              demands
              |> Enum.map(
                &system_placement(
                  &1,
                  target_node,
                  score,
                  node,
                  get_in(group_plan, ["allocations", &1["agent_id"]]) ||
                    Allocation.empty_allocation()
                )
              )
              |> Enum.filter(&placement_selected?(&1, only_agent_ids))

            target_demands =
              target_placements
              |> Enum.map(&placement_to_demand/1)

            next_usage =
              if target_placements == [] do
                usage_acc
              else
                Map.update(
                  usage_acc,
                  target_node,
                  group_plan["usage"],
                  &Usage.merge_usage(&1, group_plan["usage"])
                )
              end

            {placement_acc ++ target_placements, demand_acc ++ target_demands, next_usage}
          end)

        {:ok, placements, placed_demands, usage}
    end
  end

  defp system_node_plan(node, demands, used, service_instances) do
    if Eligibility.schedulable_node?(node) do
      Group.group_node_plan(
        node,
        demands,
        used,
        &system_demand_eligible?(&1, node, service_instances)
      )
    else
      :error
    end
  end

  defp system_demand_eligible?(demand, node, service_instances) do
    Eligibility.profile_match?(demand["profile"], node) and
      Eligibility.constraints_match?(demand["constraints"], node) and
      Eligibility.service_requirements_match?(demand, node, service_instances)
  end

  defp system_placement(demand, target_node, score, node, allocation) do
    placement =
      %{
        "agent_id" => system_agent_id(demand["agent_id"], target_node),
        "source_agent_id" => demand["agent_id"],
        "agent_type" => demand["agent_type"],
        "node" => target_node,
        "system_target" => target_node,
        "resources" => demand["resources"],
        "allocations" => allocation,
        "constraints" => demand["constraints"],
        "placement_requirements" => demand["placement_requirements"],
        "placement_preferences" => demand["placement_preferences"]
      }

    Map.merge(placement, Scoring.placement_score_metadata(demand, node, score))
  end

  defp placement_to_demand(placement) do
    %{
      "agent_id" => placement["agent_id"],
      "agent_type" => placement["agent_type"],
      "resources" => placement["resources"],
      "resource_request" =>
        placement["resource_request"] || %{"resources" => placement["resources"]},
      "constraints" => placement["constraints"],
      "placement_preferences" => placement["placement_preferences"] || %{}
    }
  end

  defp placement_selected?(_placement, nil), do: true

  defp placement_selected?(placement, only_agent_ids) do
    placement["agent_id"] in only_agent_ids or placement["source_agent_id"] in only_agent_ids
  end

  defp normalize_agent_id_filter(nil), do: nil

  defp normalize_agent_id_filter(agent_ids) do
    agent_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp system_agent_id(agent_id, target_node), do: "#{agent_id}@#{target_node}"

  defp no_system_candidate_reason(demands, nodes, usage, service_instances) do
    demand_ids = demands |> Enum.map(& &1["agent_id"]) |> Enum.join(", ")

    reasons =
      nodes
      |> Enum.map(fn node ->
        used = Usage.usage_for_node(usage, node["name"])

        cond do
          not Eligibility.schedulable_node?(node) ->
            "#{node["name"]}: #{Eligibility.unschedulable_reason(node)}"

          not Enum.all?(demands, &system_demand_eligible?(&1, node, service_instances)) ->
            "#{node["name"]}: constraints, profiles, services, or capabilities not matched"

          not match?({:ok, _}, system_node_plan(node, demands, used, service_instances)) ->
            "#{node["name"]}: insufficient resources for system group"

          true ->
            "#{node["name"]}: unavailable"
        end
      end)

    "system job agents #{demand_ids} have no eligible nodes (#{Enum.join(reasons, "; ")})"
  end
end
