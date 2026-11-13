defmodule MirrorNeuron.Scheduler.Placement.Workloads do
  @moduledoc "Places ordinary workloads by co-location, then per-worker spillover."

  alias MirrorNeuron.Scheduler.Placement.Allocation
  alias MirrorNeuron.Scheduler.Placement.Demand
  alias MirrorNeuron.Scheduler.Placement.Diagnostics
  alias MirrorNeuron.Scheduler.Placement.Eligibility
  alias MirrorNeuron.Scheduler.Placement.Group
  alias MirrorNeuron.Scheduler.Placement.Scoring
  alias MirrorNeuron.Scheduler.Placement.SystemWorkloads
  alias MirrorNeuron.Scheduler.Placement.Usage

  @system_job_types ["system", "sysbatch"]

  def place_workloads(
        job_type,
        demands,
        nodes,
        usage,
        strategy,
        only_agent_ids,
        service_instances,
        blob_refs
      )
      when job_type in @system_job_types do
    SystemWorkloads.place_system_demands(
      demands,
      nodes,
      usage,
      strategy,
      only_agent_ids,
      service_instances,
      blob_refs
    )
  end

  def place_workloads(
        _job_type,
        demands,
        nodes,
        usage,
        strategy,
        only_agent_ids,
        service_instances,
        blob_refs
      ) do
    demands = Demand.filter_demands(demands, only_agent_ids)

    with {:ok, placements, usage} <-
           place_demands(demands, nodes, usage, strategy, service_instances, blob_refs) do
      {:ok, placements, demands, usage}
    end
  end

  defp place_demands(demands, nodes, usage, strategy, service_instances, blob_refs) do
    if Scoring.valid_preferred_node_present?(demands, nodes) do
      place_spillover_demands(demands, nodes, usage, strategy, service_instances, blob_refs)
    else
      case preferred_local_plan(demands, nodes, usage, strategy, service_instances, blob_refs) do
        {:ok, placements, next_usage} ->
          {:ok, placements, next_usage}

        :error ->
          place_spillover_demands(demands, nodes, usage, strategy, service_instances, blob_refs)
      end
    end
  end

  defp preferred_local_plan([], _nodes, usage, _strategy, _service_instances, _blob_refs),
    do: {:ok, [], usage}

  defp preferred_local_plan(demands, nodes, usage, strategy, service_instances, blob_refs) do
    nodes
    |> Enum.filter(&Eligibility.schedulable_node?/1)
    |> Enum.reduce([], fn node, acc ->
      used = Usage.usage_for_node(usage, node["name"])

      case local_node_plan(node, demands, used, service_instances) do
        {:ok, group_plan} ->
          score =
            Scoring.score_node_detail(
              node,
              used,
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
    |> case do
      [] ->
        :error

      candidates ->
        {node, group_plan, score} =
          Enum.max_by(candidates, fn {_node, _group_plan, score} -> score["score"] end)

        placements =
          Enum.map(demands, fn demand ->
            placement =
              %{
                "agent_id" => demand["agent_id"],
                "agent_type" => demand["agent_type"],
                "node" => node["name"],
                "resources" => demand["resources"],
                "allocations" =>
                  get_in(group_plan, ["allocations", demand["agent_id"]]) ||
                    Allocation.empty_allocation(),
                "constraints" => demand["constraints"],
                "placement_requirements" => demand["placement_requirements"],
                "locality" => "job_colocated"
              }

            Map.merge(placement, Scoring.placement_score_metadata(demand, node, score))
          end)

        next_usage =
          Map.update(
            usage,
            node["name"],
            group_plan["usage"],
            &Usage.merge_usage(&1, group_plan["usage"])
          )

        {:ok, placements, next_usage}
    end
  end

  defp local_node_plan(node, demands, used, service_instances) do
    Group.group_node_plan(
      node,
      demands,
      used,
      &normal_demand_eligible?(&1, node, service_instances)
    )
  end

  defp normal_demand_eligible?(demand, node, service_instances) do
    Eligibility.profile_match?(demand["profile"], node) and
      Eligibility.constraints_match?(demand["constraints"], node) and
      Eligibility.service_requirements_match?(demand, node, service_instances)
  end

  defp place_spillover_demands(demands, nodes, usage, strategy, service_instances, blob_refs) do
    Enum.reduce_while(demands, {:ok, [], usage}, fn demand, {:ok, placements, usage_acc} ->
      case choose_node(demand, nodes, usage_acc, strategy, service_instances, blob_refs) do
        {:ok, node, score, allocation} ->
          next_usage =
            Map.update(
              usage_acc,
              node["name"],
              Usage.add_usage(Usage.empty_usage(), demand["resources"], allocation),
              &Usage.add_usage(&1, demand["resources"], allocation)
            )

          placement =
            %{
              "agent_id" => demand["agent_id"],
              "agent_type" => demand["agent_type"],
              "node" => node["name"],
              "resources" => demand["resources"],
              "allocations" => allocation,
              "constraints" => demand["constraints"],
              "placement_requirements" => demand["placement_requirements"],
              "locality" => "agent_spillover"
            }
            |> Map.merge(Scoring.placement_score_metadata(demand, node, score))

          {:cont, {:ok, [placement | placements], next_usage}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, placements, usage_acc} -> {:ok, Enum.reverse(placements), usage_acc}
      error -> error
    end
  end

  defp choose_node(demand, nodes, usage, strategy, service_instances, blob_refs) do
    candidates =
      nodes
      |> Enum.filter(&Eligibility.schedulable_node?/1)
      |> Enum.filter(&Eligibility.profile_match?(demand["profile"], &1))
      |> Enum.filter(&Eligibility.constraints_match?(demand["constraints"], &1))
      |> Enum.filter(&Eligibility.service_requirements_match?(demand, &1, service_instances))
      |> Enum.flat_map(fn node ->
        used = Usage.usage_for_node(usage, node["name"])

        case Allocation.fit_allocation(node, used, demand) do
          {:ok, allocation} -> [{node, allocation}]
          {:error, _reason} -> []
        end
      end)

    case candidates do
      [] ->
        {:error, Diagnostics.no_candidate_reason(demand, nodes, usage, service_instances)}

      candidates ->
        {node, allocation, score} =
          candidates
          |> Enum.map(fn {node, allocation} ->
            {node, allocation,
             Scoring.score_node_detail(
               node,
               Usage.usage_for_node(usage, node["name"]),
               demand["resources"],
               strategy,
               blob_refs,
               [demand]
             )}
          end)
          |> Enum.max_by(fn {_node, _allocation, score} -> score["score"] end)

        {:ok, node, score, allocation}
    end
  end
end
