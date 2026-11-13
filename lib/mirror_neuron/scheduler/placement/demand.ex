defmodule MirrorNeuron.Scheduler.Placement.Demand do
  @moduledoc "Normalizes worker resources, constraints, profiles and placement preferences."

  alias MirrorNeuron.Scheduler.ResourceInference
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.ServiceSpec
  alias MirrorNeuron.Scheduler.Placement.Values

  def workload_demands(manifest) do
    global_constraints = scheduler_constraints(manifest.policies)

    demands =
      Enum.map(manifest.nodes, fn node ->
        resource_request = resource_request_for_node(node)
        constraints = global_constraints ++ constraints_for_node(node)
        requires_services = ServiceSpec.node_requires_services(node)

        inferred =
          ResourceInference.infer(
            manifest,
            node,
            resource_request,
            constraints,
            requires_services
          )

        resource_request = inferred["resource_request"]

        %{
          "agent_id" => node.node_id,
          "agent_type" => node.agent_type,
          "resources" => resource_request["resources"],
          "resource_request" => resource_request,
          "constraints" => inferred["constraints"],
          "profile" => execution_profile(node),
          "requires_services" => inferred["requires_services"],
          "placement_requirements" => inferred["placement_requirements"],
          "placement_preferences" => placement_preferences(node)
        }
      end)

    {:ok, demands}
  end

  defp scheduler_constraints(policies) when is_map(policies) do
    []
    |> Kernel.++(normalize_constraints(Map.get(policies, "constraints", [])))
    |> Kernel.++(normalize_constraints(get_in(policies, ["scheduler", "constraints"]) || []))
  end

  defp scheduler_constraints(_policies), do: []

  defp resource_request_for_node(node) do
    explicit =
      Map.get(node, :resources) ||
        Map.get(node, "resources") ||
        get_in(node, [:config, "resources"]) ||
        get_in(node, ["config", "resources"]) ||
        %{}

    explicit
    |> ResourceSpec.normalize_request()
    |> add_profile_gpu_need(node)
    |> ResourceSpec.with_runtime_driver(ResourceSpec.infer_runtime_driver(node_config(node)))
  end

  defp constraints_for_node(node) do
    constraints =
      Map.get(node, :constraints) ||
        Map.get(node, "constraints") ||
        get_in(node, [:config, "constraints"]) ||
        get_in(node, ["config", "constraints"]) ||
        []

    normalize_constraints(constraints)
  end

  defp execution_profile(node) do
    MirrorNeuron.Execution.Profile.profile_name(
      Map.get(node, :config) || Map.get(node, "config") || %{}
    )
  end

  defp node_config(node), do: Map.get(node, :config) || Map.get(node, "config") || %{}

  defp placement_preferences(node) do
    policies = Map.get(node, :policies) || Map.get(node, "policies") || %{}
    scheduler = Values.map_get(policies, "scheduler") || %{}

    preferred_node =
      Values.map_get(scheduler, "preferred_node") ||
        Values.map_get(scheduler, "preferredNode") ||
        Values.map_get(policies, "preferred_node") ||
        Values.map_get(policies, "preferredNode")

    %{"preferred_node" => normalize_preferred_node(preferred_node)}
  end

  defp add_profile_gpu_need(resource_request, node) do
    case execution_profile(node) do
      nil ->
        resource_request

      profile_name ->
        case MirrorNeuron.Execution.Profile.fetch(profile_name) do
          {:ok, %{"gpu" => gpu?}}
          when gpu? in [true, "true", "TRUE", "True", "1", 1, "yes", "on"] ->
            ResourceSpec.add_gpu_need(resource_request, 1)

          _ ->
            resource_request
        end
    end
  end

  defp normalize_constraints(constraints) when is_list(constraints) do
    Enum.map(constraints, &normalize_constraint/1)
  end

  defp normalize_constraints(constraint) when is_map(constraint),
    do: [normalize_constraint(constraint)]

  defp normalize_constraints(_constraints), do: []

  defp normalize_constraint(constraint) when is_map(constraint) do
    %{
      "attribute" =>
        Map.get(constraint, "attribute") ||
          Map.get(constraint, :attribute) ||
          Map.get(constraint, "target") ||
          Map.get(constraint, :target) ||
          Map.get(constraint, "l_target") ||
          Map.get(constraint, :l_target),
      "operator" =>
        Map.get(constraint, "operator") ||
          Map.get(constraint, :operator) ||
          Map.get(constraint, "operand") ||
          Map.get(constraint, :operand) ||
          "==",
      "value" =>
        Map.get(constraint, "value") ||
          Map.get(constraint, :value) ||
          Map.get(constraint, "r_target") ||
          Map.get(constraint, :r_target)
    }
  end

  defp normalize_constraint(value) when is_binary(value) do
    %{"attribute" => "capabilities", "operator" => "contains", "value" => value}
  end

  defp normalize_constraint(value) do
    %{"attribute" => "capabilities", "operator" => "contains", "value" => to_string(value)}
  end

  def filter_demands(demands, nil), do: demands

  def filter_demands(demands, agent_ids) do
    agent_ids =
      agent_ids
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.filter(demands, &(Map.get(&1, "agent_id") in agent_ids))
  end

  def normalize_preferred_node(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def normalize_preferred_node(nil), do: nil

  def normalize_preferred_node(value), do: normalize_preferred_node(to_string(value))
end
