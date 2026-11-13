defmodule MirrorNeuron.Scheduler.Placement.Diagnostics do
  @moduledoc "Explains placement failures using the same eligibility and allocation predicates."

  alias MirrorNeuron.Scheduler.AdmissionProblem
  alias MirrorNeuron.Scheduler.Placement.Allocation
  alias MirrorNeuron.Scheduler.Placement.Eligibility
  alias MirrorNeuron.Scheduler.Placement.Usage

  def no_candidate_reason(demand, nodes, usage, service_instances) do
    reasons =
      nodes
      |> Enum.map(fn node ->
        cond do
          not Eligibility.schedulable_node?(node) ->
            "#{node["name"]}: #{Eligibility.unschedulable_reason(node)}"

          not Eligibility.profile_match?(demand["profile"], node) ->
            "#{node["name"]}: execution profile not available"

          not Eligibility.constraints_match?(demand["constraints"], node) ->
            "#{node["name"]}: constraints not matched"

          not Eligibility.service_requirements_match?(demand, node, service_instances) ->
            "#{node["name"]}: required services not available"

          not Allocation.capacity_available?(
            node,
            Usage.usage_for_node(usage, node["name"]),
            demand["resources"]
          ) ->
            "#{node["name"]}: insufficient resources"

          not match?(
            {:ok, _allocation},
            Allocation.fit_allocation(node, Usage.usage_for_node(usage, node["name"]), demand)
          ) ->
            "#{node["name"]}: devices, ports, volumes, or runtime driver not available"

          true ->
            "#{node["name"]}: unavailable"
        end
      end)

    requirement_text = demand_requirement_text(demand)

    "agent #{demand["agent_id"]}#{requirement_text} has no eligible node (#{Enum.join(reasons, "; ")})" <>
      AdmissionProblem.encode(admission_blockers(demand, nodes, usage, service_instances))
  end

  defp admission_blockers(demand, nodes, usage, service_instances) do
    nodes
    |> Enum.sort_by(& &1["name"])
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {node, index} ->
      used = Usage.usage_for_node(usage, node["name"]) |> Usage.normalize_usage()

      cond do
        not Eligibility.constraints_match?(demand["constraints"], node) ->
          []

        not Eligibility.schedulable_node?(node) ->
          code =
            if node["coordination_store_rejection"],
              do: "MN_PLACEMENT_UNSATISFIED",
              else: "MN_SCHEDULING_UNAVAILABLE"

          [AdmissionProblem.blocker(code, node, index)]

        not Eligibility.profile_match?(demand["profile"], node) or
            not Eligibility.service_requirements_match?(demand, node, service_instances) ->
          [AdmissionProblem.blocker("MN_PLACEMENT_UNSATISFIED", node, index)]

        true ->
          AdmissionProblem.allocation_blockers(
            Allocation.fit_allocation(node, used, demand),
            node,
            used,
            demand,
            index,
            &Allocation.device_matches?/2
          )
      end
    end)
  end

  defp demand_requirement_text(%{"placement_requirements" => %{"models" => models}})
       when is_list(models) and models != [] do
    details =
      models
      |> Enum.map(fn model ->
        service = get_in(model, ["service", "name"])
        capabilities = Map.get(model, "required_capabilities", [])
        min_vram = Map.get(model, "min_vram_mb")

        [
          Map.get(model, "id") || Map.get(model, "model"),
          if(service, do: "service #{service}", else: nil),
          if(is_number(min_vram), do: "gpu >= #{Float.round(min_vram / 1024, 1)}GB", else: nil),
          if(capabilities != [],
            do: "capability any of #{Enum.join(capabilities, ",")}",
            else: nil
          )
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
      end)
      |> Enum.reject(&(&1 == ""))

    if details == [] do
      ""
    else
      " requiring #{Enum.join(details, "; ")}"
    end
  end

  defp demand_requirement_text(_demand), do: ""
end
