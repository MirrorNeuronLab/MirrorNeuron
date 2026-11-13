defmodule MirrorNeuron.Scheduler.Placement.Scoring do
  @moduledoc "Ranks eligible nodes by preference, hardware power, blob locality and strategy."

  alias MirrorNeuron.Artifacts.BlobRef
  alias MirrorNeuron.Scheduler.Placement.Demand
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Scheduler.Placement.Usage
  alias MirrorNeuron.Scheduler.Placement.Values

  @resource_keys ResourceSpec.resource_keys()
  @preferred_node_bonus 10_000.0
  @strategy_tiebreak_weight 0.01

  def score_node_detail(node, used, ask, strategy, blob_refs, demands) do
    strategy_score = strategy_score_node(node, used, ask, strategy)
    power_score = node_power_score(node, ask, demands)
    blob_bonus = blob_locality_bonus(node, blob_refs)
    preferred_bonus = preferred_node_bonus(node, demands)
    locality = blob_locality_summary(node, blob_refs)

    score =
      preferred_bonus + power_score + blob_bonus + strategy_score * @strategy_tiebreak_weight

    %{
      "score" => score,
      "power_score" => power_score,
      "blob_locality_bonus" => blob_bonus,
      "strategy_score" => strategy_score,
      "preferred_node_bonus" => preferred_bonus,
      "blob_locality" => locality
    }
  end

  defp strategy_score_node(node, used, ask, "spread") do
    capacity = node["capacity"] || Usage.empty_resources()

    @resource_keys
    |> Enum.map(&resource_ratio(capacity, used, ask, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 1.0
      ratios -> 1.0 - Enum.sum(ratios) / length(ratios)
    end
  end

  defp strategy_score_node(node, used, ask, _binpack) do
    capacity = node["capacity"] || Usage.empty_resources()

    @resource_keys
    |> Enum.map(&resource_ratio(capacity, used, ask, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0.0
      ratios -> Enum.sum(ratios) / length(ratios)
    end
  end

  defp node_power_score(node, ask, demands) do
    capacity = node["capacity"] || Usage.empty_resources()
    cpu = Values.number_value(Map.get(capacity, "cpu_cores")) || 0.0
    memory_gb = (Values.number_value(Map.get(capacity, "memory_mb")) || 0.0) / 1024.0

    cpu_memory_score =
      log2(cpu + 1.0) * 0.6 +
        log2(memory_gb + 1.0) * 0.4

    if gpu_sensitive?(ask, demands) do
      gpu_count = Values.number_value(Map.get(capacity, "gpu_count")) || 0.0
      gpu_memory_gb = node_gpu_memory_mb(node) / 1024.0

      cpu_memory_score +
        5.0 +
        gpu_count * 2.0 +
        log2(gpu_memory_gb + 1.0) * 2.0
    else
      cpu_memory_score
    end
  end

  defp log2(value) when value > 0, do: :math.log(value) / :math.log(2)

  defp log2(_value), do: 0.0

  defp gpu_sensitive?(ask, demands) do
    (Values.number_value(Map.get(ask || %{}, "gpu_count")) || 0) > 0 or
      Enum.any?(List.wrap(demands), &demand_model_gpu_sensitive?/1)
  end

  defp demand_model_gpu_sensitive?(%{"placement_requirements" => %{"models" => models}})
       when is_list(models) do
    Enum.any?(models, fn model ->
      is_number(Map.get(model, "min_vram_mb")) or
        is_number(Map.get(model, "min_unified_memory_mb")) or
        List.wrap(Map.get(model, "required_capabilities")) != []
    end)
  end

  defp demand_model_gpu_sensitive?(_demand), do: false

  defp node_gpu_memory_mb(node) do
    node
    |> Map.get("devices", [])
    |> List.wrap()
    |> Enum.filter(fn device ->
      kind = String.downcase(to_string(Map.get(device, "kind") || ""))
      type = String.downcase(to_string(Map.get(device, "type") || ""))
      String.contains?(kind, "gpu") or String.contains?(type, "gpu")
    end)
    |> Enum.map(fn device ->
      Values.number_value(Map.get(device, "memory_free_mb")) ||
        Values.number_value(Map.get(device, "memory_total_mb")) ||
        0
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp preferred_node_bonus(node, demands) do
    preferred =
      demands
      |> List.wrap()
      |> Enum.map(&preferred_node_for_demand/1)
      |> Enum.reject(&is_nil/1)

    if preferred == [] do
      0.0
    else
      matches = Enum.count(preferred, &(&1 == Map.get(node, "name")))
      @preferred_node_bonus * (matches / length(preferred))
    end
  end

  def valid_preferred_node_present?(demands, nodes) do
    node_names =
      nodes
      |> Enum.map(&Map.get(&1, "name"))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.any?(demands, fn demand ->
      preferred = preferred_node_for_demand(demand)
      is_binary(preferred) and MapSet.member?(node_names, preferred)
    end)
  end

  defp preferred_node_for_demand(%{"placement_preferences" => preferences})
       when is_map(preferences) do
    Demand.normalize_preferred_node(Map.get(preferences, "preferred_node"))
  end

  defp preferred_node_for_demand(_demand), do: nil

  def placement_score_metadata(demand, node, score) do
    preferred_node = preferred_node_for_demand(demand)

    %{
      "placement_preferences" => demand["placement_preferences"] || %{},
      "blob_locality" => score["blob_locality"],
      "power_score" => Float.round(score["power_score"], 4),
      "score" => Float.round(score["score"], 4),
      "scheduler_score" => %{
        "power" => Float.round(score["power_score"], 4),
        "blob_locality_bonus" => Float.round(score["blob_locality_bonus"], 4),
        "strategy" => Float.round(score["strategy_score"], 4),
        "preferred_node_bonus" => Float.round(score["preferred_node_bonus"], 4)
      }
    }
    |> maybe_put("preferred_node", preferred_node)
    |> maybe_put("preferred_node_status", preferred_node_status(preferred_node, node))
  end

  defp preferred_node_status(nil, _node), do: nil

  defp preferred_node_status(preferred_node, node) do
    if preferred_node == Map.get(node, "name"), do: "honored", else: "fallback"
  end

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blob_locality_bonus(_node, []), do: 0.0

  defp blob_locality_bonus(node, blob_refs) do
    summary = blob_locality_summary(node, blob_refs)
    required = Map.get(summary, "required_count", 0)
    local = Map.get(summary, "local_count", 0)

    if required > 0 do
      0.25 * (local / required)
    else
      0.0
    end
  end

  defp blob_locality_summary(_node, []),
    do: %{"required_count" => 0, "local_count" => 0, "missing_count" => 0}

  defp blob_locality_summary(node, blob_refs) do
    node_name = Map.get(node, "name")
    refs = Enum.map(blob_refs, &BlobRef.normalize/1) |> Enum.filter(&BlobRef.valid?/1)

    local_count =
      Enum.count(refs, fn ref ->
        blob_available_on_node?(ref, node_name)
      end)

    %{
      "required_count" => length(refs),
      "local_count" => local_count,
      "missing_count" => max(length(refs) - local_count, 0)
    }
  end

  defp blob_available_on_node?(ref, node_name) do
    ref
    |> blob_locations()
    |> Enum.any?(&(shared_blob_location?(&1) or Map.get(&1, "node") == node_name))
  end

  defp shared_blob_location?(location) do
    storage = Map.get(location, "storage") || Map.get(location, "type")
    storage in ["shared_fs", "shared_fs_cas"]
  end

  defp blob_locations(ref) do
    inline_locations = List.wrap(Map.get(ref, "locations", []))

    if inline_locations != [] do
      inline_locations
    else
      case RedisStore.fetch_blob_ref(Map.get(ref, "sha256")) do
        {:ok, %{"locations" => locations}} when is_list(locations) -> locations
        _ -> []
      end
    end
  rescue
    _ -> List.wrap(Map.get(ref, "locations", []))
  end

  defp resource_ratio(capacity, used, ask, key) do
    total = Map.get(capacity, key, 0)
    used_resources = Usage.normalize_usage(used)["resources"]

    if total > 0 do
      (Map.get(used_resources, key, 0) + Map.get(ask, key, 0)) / total
    else
      nil
    end
  end
end
