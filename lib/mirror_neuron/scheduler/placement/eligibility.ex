defmodule MirrorNeuron.Scheduler.Placement.Eligibility do
  @moduledoc "Evaluates node status, constraints, execution profiles and required services."

  alias MirrorNeuron.ServiceRegistry
  alias MirrorNeuron.Scheduler.Placement.Values

  @active_node_statuses ["healthy", "joining"]

  def service_requirements_match?(
        %{"requires_services" => requirements},
        _node,
        _service_instances
      )
      when requirements in [nil, []],
      do: true

  def service_requirements_match?(
        %{"requires_services" => requirements},
        node,
        service_instances
      ) do
    ServiceRegistry.requirements_satisfied_on_node?(requirements, node["name"],
      service_instances: service_instances
    )
  end

  def service_requirements_match?(_demand, _node, _service_instances), do: true

  def schedulable_node?(node) do
    Map.get(node, "status") in @active_node_statuses and
      Map.get(node, "scheduling_eligible", true) != false
  end

  def unschedulable_reason(node) do
    cond do
      Map.get(node, "status") not in @active_node_statuses ->
        "status #{inspect(node["status"])}"

      Map.get(node, "scheduling_eligible", true) == false ->
        Map.get(node, "coordination_store_rejection") || "scheduling is disabled"

      true ->
        "unavailable"
    end
  end

  def constraints_match?(constraints, node) do
    Enum.all?(constraints, &constraint_match?(&1, node))
  end

  defp constraint_match?(
         %{"attribute" => attribute, "operator" => operator, "value" => value},
         node
       ) do
    current = node_attribute(node, attribute)

    case normalize_operator(operator) do
      "==" -> to_string(current) == to_string(value)
      "!=" -> to_string(current) != to_string(value)
      "contains" -> to_string(value) in Values.list_value(current)
      "contains_all" -> Enum.all?(Values.list_value(value), &(&1 in Values.list_value(current)))
      "contains_any" -> Enum.any?(Values.list_value(value), &(&1 in Values.list_value(current)))
      "in" -> to_string(current) in Values.list_value(value)
      "exists" -> not is_nil(current)
      "not_exists" -> is_nil(current)
      _ -> false
    end
  end

  defp constraint_match?(_constraint, _node), do: true

  def profile_match?(nil, _node), do: true

  def profile_match?(profile, node) do
    MirrorNeuron.Execution.Profile.eligible_node?(profile, %{
      "node" => node["name"],
      "status" => node["status"],
      "profiles" => node["profiles"],
      "capabilities" => node["capabilities"],
      "gpu" => node["gpu"]
    })
  end

  defp normalize_operator(operator) do
    case operator |> to_string() |> String.downcase() do
      "=" -> "=="
      "==" -> "=="
      "is" -> "=="
      "!=" -> "!="
      "not" -> "!="
      "set_contains" -> "contains"
      "contains" -> "contains"
      "set_contains_all" -> "contains_all"
      "contains_all" -> "contains_all"
      "set_contains_any" -> "contains_any"
      "contains_any" -> "contains_any"
      "in" -> "in"
      "is_set" -> "exists"
      "exists" -> "exists"
      "is_not_set" -> "not_exists"
      "not_exists" -> "not_exists"
      other -> other
    end
  end

  defp node_attribute(node, attribute) do
    case attribute |> to_string() |> String.trim("${}") do
      value when value in ["node", "node.name", "node.unique.name"] ->
        node["name"]

      value when value in ["status", "node.status"] ->
        node["status"]

      value when value in ["node_role", "role", "node.role"] ->
        node["node_role"]

      value when value in ["gpu", "node.gpu"] ->
        node["gpu"]

      value when value in ["profiles", "profile", "execution_profile"] ->
        node["profiles"]

      value when value in ["capabilities", "capability"] ->
        node["capabilities"]

      value when value in ["os", "platform.os"] ->
        get_in(node, ["hardware", "platform", "os"]) ||
          get_in(node, ["hardware", "platform", "family"])

      value when value in ["arch", "architecture", "cpu.arch"] ->
        get_in(node, ["hardware", "cpu", "architecture"])

      path ->
        Values.get_path(node, String.split(path, "."))
    end
  end
end
