defmodule MirrorNeuron.HardwareRequirements do
  @moduledoc false

  alias MirrorNeuron.ResourceSpec

  @active_node_statuses ["healthy", "joining"]
  @version_operators [">", ">=", "=", "=="]

  def gpu_requirement(requirements) when is_map(requirements) do
    case map_get(requirements, "gpu") do
      gpu when is_map(gpu) ->
        %{
          "min_count" =>
            number_value(
              map_get(gpu, "min_count") || map_get(gpu, "count") || map_get(gpu, "min")
            ),
          "vendor" => normalize_text(map_get(gpu, "vendor")),
          "driver" => normalize_text(map_get(gpu, "driver")),
          "min_api_version" => blank_to_nil(map_get(gpu, "min_api_version")),
          "api_version_operator" => normalize_operator(map_get(gpu, "api_version_operator")),
          "min_memory_mb" => number_value(map_get(gpu, "min_memory_mb")),
          "memory_operator" => normalize_operator(map_get(gpu, "memory_operator")),
          "required_capabilities" =>
            normalize_capabilities(map_get(gpu, "required_capabilities")),
          "enforcement" => normalize_text(map_get(gpu, "enforcement"))
        }

      gpu ->
        case number_value(gpu) do
          nil -> nil
          count -> %{"min_count" => count}
        end
    end
  end

  def gpu_requirement(_requirements), do: nil

  def hard_gpu_requirement?(requirements) do
    case gpu_requirement(requirements) do
      %{"enforcement" => "hard"} -> true
      _ -> false
    end
  end

  def gpu_requirement_active?(requirements) do
    case gpu_requirement(requirements) do
      nil -> false
      %{} = requirement -> gpu_requirement_fields(requirement) != []
    end
  end

  def matching_nodes(requirements, snapshot) do
    requirement = gpu_requirement(requirements)

    if is_nil(requirement) do
      []
    else
      snapshot
      |> nodes_from_snapshot()
      |> Enum.filter(&working_node?/1)
      |> Enum.filter(&node_satisfies_gpu?(&1, requirement))
    end
  end

  def gpu_requirement_issue(requirements, snapshot) do
    requirement = gpu_requirement(requirements)

    cond do
      is_nil(requirement) or gpu_requirement_fields(requirement) == [] ->
        nil

      matching_nodes(requirements, snapshot) != [] ->
        nil

      true ->
        %{
          code: "requirements.gpu_node_unavailable",
          message: "This blueprint needs #{gpu_requirement_label(requirement)}.",
          help:
            "Add or connect a healthy, scheduling-eligible NVIDIA CUDA runtime node that satisfies this GPU requirement, then launch again.",
          expected: expected_gpu(requirement),
          actual: actual_gpu(snapshot)
        }
    end
  end

  def node_satisfies_gpu?(node, requirement) when is_map(node) and is_map(requirement) do
    devices = gpu_devices(node)
    min_count = requirement["min_count"] || 1
    matched = Enum.filter(devices, &device_satisfies_gpu?(&1, requirement))

    length(matched) >= trunc(min_count)
  end

  def node_satisfies_gpu?(_node, _requirement), do: false

  def device_satisfies_gpu?(device, requirement) when is_map(device) and is_map(requirement) do
    device = stringify_map(device)
    capabilities = normalize_capabilities(map_get(device, "capabilities"))
    requirement_capabilities = requirement["required_capabilities"] || []

    Enum.all?([
      gpu_device?(device, capabilities),
      blank?(requirement["vendor"]) or
        requirement["vendor"] == normalize_text(map_get(device, "vendor")),
      blank?(requirement["driver"]) or
        requirement["driver"] == normalize_text(map_get(device, "driver")),
      requirement_capabilities == [] or Enum.any?(requirement_capabilities, &(&1 in capabilities)),
      version_matches?(
        map_get(device, "api_version"),
        requirement["min_api_version"],
        requirement["api_version_operator"] || ">="
      ),
      memory_matches?(
        map_get(device, "memory_free_mb") || map_get(device, "memory_total_mb"),
        requirement["min_memory_mb"],
        requirement["memory_operator"] || ">="
      )
    ])
  end

  def device_satisfies_gpu?(_device, _requirement), do: false

  def version_matches?(_actual, nil, _operator), do: true
  def version_matches?(nil, _minimum, _operator), do: false

  def version_matches?(actual, minimum, operator) do
    case {version_parts(actual), version_parts(minimum)} do
      {[], _} ->
        false

      {_, []} ->
        true

      {actual_parts, minimum_parts} ->
        compare_value(compare_versions(actual_parts, minimum_parts), operator)
    end
  end

  def memory_matches?(_actual, nil, _operator), do: true
  def memory_matches?(nil, _minimum, _operator), do: false

  def memory_matches?(actual, minimum, operator) do
    actual = number_value(actual)
    minimum = number_value(minimum)

    cond do
      is_nil(actual) or is_nil(minimum) -> false
      true -> compare_value(compare_numbers(actual, minimum), operator)
    end
  end

  def working_node?(node) when is_map(node) do
    node = stringify_map(node)
    status = normalize_text(map_get(node, "status") || "healthy")
    scheduling_eligible = map_get(node, "scheduling_eligible")
    drain = map_get(node, "drain")
    maintenance = map_get(node, "maintenance")

    status in @active_node_statuses and scheduling_eligible != false and not truthy?(drain) and
      not truthy?(maintenance)
  end

  def working_node?(_node), do: false

  def expected_gpu(requirement) do
    %{
      "resource" => "gpu",
      "min_count" => requirement["min_count"] || 1,
      "vendor" => requirement["vendor"],
      "driver" => requirement["driver"],
      "min_api_version" => requirement["min_api_version"],
      "api_version_operator" => requirement["api_version_operator"] || ">=",
      "min_memory_mb" => requirement["min_memory_mb"],
      "memory_operator" => requirement["memory_operator"] || ">=",
      "enforcement" => requirement["enforcement"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  def actual_gpu(snapshot) do
    nodes =
      snapshot
      |> nodes_from_snapshot()
      |> Enum.map(fn node ->
        %{
          "name" => map_get(node, "name") || map_get(node, "node") || "unknown",
          "status" => map_get(node, "status") || "healthy",
          "scheduling_eligible" => map_get(node, "scheduling_eligible"),
          "gpu_count" => length(gpu_devices(node)),
          "devices" =>
            node
            |> gpu_devices()
            |> Enum.map(fn device ->
              device = stringify_map(device)

              %{
                "name" => map_get(device, "name") || map_get(device, "model"),
                "vendor" => map_get(device, "vendor"),
                "driver" => map_get(device, "driver"),
                "api_version" => map_get(device, "api_version"),
                "memory_total_mb" => map_get(device, "memory_total_mb"),
                "memory_free_mb" => map_get(device, "memory_free_mb"),
                "capabilities" => map_get(device, "capabilities") || []
              }
            end)
        }
      end)

    %{"nodes" => nodes}
  end

  def gpu_requirement_label(requirement) do
    [
      "#{format_count(requirement["min_count"] || 1)} NVIDIA CUDA runtime node",
      if(requirement["min_memory_mb"],
        do:
          "GPU memory #{requirement["memory_operator"] || ">="} #{format_mb(requirement["min_memory_mb"])}",
        else: nil
      ),
      if(requirement["min_api_version"],
        do:
          "CUDA #{requirement["api_version_operator"] || ">="} #{requirement["min_api_version"]}",
        else: nil
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" with ")
  end

  defp nodes_from_snapshot(snapshot) when is_map(snapshot) do
    snapshot = stringify_map(snapshot)

    cond do
      is_list(map_get(snapshot, "nodes")) ->
        map_get(snapshot, "nodes")

      is_map(map_get(snapshot, "hardware")) ->
        [snapshot]

      true ->
        [%{"name" => "local", "status" => "healthy", "hardware" => snapshot}]
    end
  end

  defp nodes_from_snapshot(_snapshot), do: []

  defp gpu_devices(node) when is_map(node) do
    node = stringify_map(node)

    cond do
      is_list(map_get(node, "devices")) ->
        map_get(node, "devices")

      true ->
        ResourceSpec.normalize_node_devices(%{"hardware" => map_get(node, "hardware") || node})
    end
  end

  defp gpu_devices(_node), do: []

  defp gpu_device?(device, capabilities) do
    kind = normalize_text(map_get(device, "kind"))
    type = normalize_text(map_get(device, "type"))

    kind == "gpu" or String.contains?(type || "", "gpu") or "gpu" in capabilities
  end

  defp gpu_requirement_fields(requirement) do
    requirement
    |> Enum.reject(fn
      {"api_version_operator", _value} -> true
      {"memory_operator", _value} -> true
      {"enforcement", _value} -> true
      {_key, value} when value in [nil, "", []] -> true
      {_key, _value} -> false
    end)
  end

  defp normalize_operator(operator) do
    operator = to_string(operator || ">=") |> String.trim()

    if operator in @version_operators do
      if operator == "=", do: "==", else: operator
    else
      ">="
    end
  end

  defp compare_value(:gt, operator), do: operator in [">", ">="]
  defp compare_value(:eq, operator), do: operator in [">=", "=="]
  defp compare_value(:lt, _operator), do: false

  defp compare_numbers(actual, minimum) when actual > minimum, do: :gt
  defp compare_numbers(actual, minimum) when actual == minimum, do: :eq
  defp compare_numbers(_actual, _minimum), do: :lt

  defp compare_versions([], []), do: :eq

  defp compare_versions([left | left_rest], [right | right_rest]) when left == right,
    do: compare_versions(left_rest, right_rest)

  defp compare_versions([left | _left_rest], [right | _right_rest]) when left > right, do: :gt
  defp compare_versions([_left | _left_rest], [_right | _right_rest]), do: :lt
  defp compare_versions([], [right | right_rest]), do: compare_versions([0], [right | right_rest])
  defp compare_versions([left | left_rest], []), do: compare_versions([left | left_rest], [0])

  defp version_parts(value) do
    value
    |> to_string()
    |> String.split(~r/[^0-9]+/, trim: true)
    |> Enum.map(&String.to_integer/1)
  rescue
    _ -> []
  end

  defp normalize_capabilities(value) do
    value
    |> List.wrap()
    |> Enum.map(&(to_string(&1) |> String.downcase() |> String.replace("_", "-")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_text(nil), do: nil
  defp normalize_text(value), do: value |> to_string() |> String.downcase() |> String.trim()

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case to_string(value) |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp number_value(value) when is_integer(value) or is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _unit} -> number
      _ -> nil
    end
  end

  defp number_value(_value), do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_map(value), do: value

  defp map_get(map, key) when is_map(map) do
    MirrorNeuron.SafeAccess.map_get(map, key)
  end

  defp map_get(_map, _key), do: nil

  defp truthy?(value) when value in [true, 1, "1", "true", "TRUE", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp format_count(1), do: "an"
  defp format_count(1.0), do: "an"
  defp format_count(value), do: "#{trunc(value)}"

  defp format_mb(value) do
    gb = number_value(value) / 1024
    "#{Float.round(gb, 1)}GB"
  end
end
