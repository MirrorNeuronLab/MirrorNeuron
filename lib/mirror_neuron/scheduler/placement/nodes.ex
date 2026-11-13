defmodule MirrorNeuron.Scheduler.Placement.Nodes do
  @moduledoc "Normalizes node advertisements and validates coordination-store eligibility."

  alias MirrorNeuron.Scheduler.Placement.Eligibility
  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Resource
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Scheduler.Placement.Values

  def allocated_capacity(nodes, %{"mode" => "shared"} = allocation) do
    allowed = MapSet.new(Enum.map(allocation["devices"] || [], & &1["id"]))

    Enum.map(nodes, fn node ->
      devices = Enum.filter(node["devices"], &MapSet.member?(allowed, &1["id"]))
      capacity = Map.merge(node["capacity"], allocation["resources"])
      capacity = Map.put(capacity, "gpu_count", length(devices))
      node |> Map.put("devices", devices) |> Map.put("capacity", capacity)
    end)
  end

  def allocated_capacity(nodes, _), do: nodes

  def exclusive_capacity(nodes, opts) do
    if Keyword.get(opts, :exclusive_run, false) and
         not Keyword.get(opts, :require_live_capacity, false) do
      Enum.map(nodes, fn node ->
        total = Values.number_value(get_in(node, ["hardware", "memory", "total_mb"]))

        capacity =
          if total,
            do: Map.put(node["capacity"], "memory_mb", total * Resource.limit_ratio(:memory)),
            else: node["capacity"]

        devices =
          Enum.map(node["devices"], fn device ->
            if is_number(device["memory_total_mb"]),
              do: Map.put(device, "memory_free_mb", device["memory_total_mb"]),
              else: device
          end)

        node |> Map.put("capacity", capacity) |> Map.put("devices", devices)
      end)
    else
      if Keyword.get(opts, :exclusive_run, false) do
        Enum.map(nodes, fn node ->
          case Values.number_value(get_in(node, ["hardware", "memory", "available_mb"])) do
            value when is_number(value) ->
              put_in(
                node,
                ["capacity", "memory_mb"],
                max(value, 0) * Resource.limit_ratio(:memory)
              )

            _ ->
              node
          end
        end)
      else
        nodes
      end
    end
  end

  def default_nodes do
    case MirrorNeuron.inspect_nodes() do
      nodes when is_list(nodes) and nodes != [] ->
        nodes

      _ ->
        [%{"name" => to_string(Node.self()), "hardware" => Hardware.info()}]
    end
  rescue
    _ -> [%{"name" => to_string(Node.self()), "hardware" => Hardware.info()}]
  end

  def normalize_nodes(nodes, lookup_node_state, coordination_store) do
    nodes
    |> List.wrap()
    |> Enum.map(&normalize_node(&1, lookup_node_state, coordination_store))
    |> Enum.reject(&is_nil/1)
  end

  def exclude_nodes(nodes, excluded) do
    excluded =
      excluded
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.reject(nodes, &(Map.get(&1, "name") in excluded))
  end

  defp normalize_node(node, lookup_node_state, coordination_store) when is_map(node) do
    name = Values.map_get(node, "name") || Values.map_get(node, "node") || to_string(Node.self())
    stored = if lookup_node_state, do: stored_node_state(name), else: %{}

    hardware =
      Values.map_get(node, "hardware") || Values.map_get(stored, "hardware") ||
        local_hardware(name)

    status = Values.map_get(node, "status") || Values.map_get(stored, "status") || "healthy"
    hardware = Values.stringify_map(hardware)
    stored = Values.stringify_map(stored)

    node_with_state =
      stored
      |> Map.merge(Values.stringify_map(node))
      |> Map.put("hardware", hardware)

    host_paths =
      ResourceSpec.normalize_node_host_paths(
        node_with_state,
        hardware
      )

    runtime_drivers =
      ResourceSpec.normalize_node_runtime_drivers(
        node_with_state,
        hardware
      )

    scheduling_eligible =
      Values.map_get(node, "scheduling_eligible")
      |> case do
        nil -> Values.map_get(stored, "scheduling_eligible")
        value -> value
      end
      |> eligible_value()

    node_coordination_store =
      if name == to_string(Node.self()) and is_map(coordination_store) do
        coordination_store
      else
        Values.map_get(node, "coordination_store") ||
          Values.map_get(stored, "coordination_store")
      end

    capabilities =
      []
      |> Kernel.++(Values.list_value(Values.map_get(node, "capabilities")))
      |> Kernel.++(Values.list_value(Values.map_get(stored, "capabilities")))
      |> Kernel.++(Values.list_value(Values.map_get(hardware, "capabilities")))
      |> Kernel.++(
        hardware
        |> Values.map_get("devices")
        |> List.wrap()
        |> Enum.flat_map(&Values.list_value(Values.map_get(&1, "capabilities")))
      )
      |> Kernel.++(
        hardware
        |> Values.map_get("gpu")
        |> List.wrap()
        |> Enum.flat_map(fn
          gpu when is_map(gpu) -> Values.list_value(Values.map_get(gpu, "capabilities"))
          _gpu -> []
        end)
      )
      |> Enum.map(&(to_string(&1) |> String.downcase() |> String.replace("_", "-")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{
      "name" => name,
      "display_name" =>
        Values.map_get(node, "display_name") ||
          get_in(hardware, ["platform", "display_name"]) ||
          get_in(hardware, ["platform", "hostname"]),
      "status" => status,
      "scheduling_eligible" => scheduling_eligible,
      "coordination_store" => Values.stringify_map(node_coordination_store || %{}),
      "drain" => Values.map_get(node, "drain") || Values.map_get(stored, "drain"),
      "hardware" => hardware,
      "profiles" =>
        Values.list_value(Values.map_get(node, "profiles") || Values.map_get(stored, "profiles")),
      "capabilities" => capabilities,
      "gpu" =>
        truthy?(Values.map_get(node, "gpu") || Values.map_get(stored, "gpu")) ||
          gpu_count(hardware) > 0,
      "node_role" =>
        Values.map_get(node, "node_role") || Values.map_get(stored, "node_role") || "runtime",
      "capacity" => node_capacity(hardware),
      "devices" => ResourceSpec.normalize_node_devices(node_with_state),
      "host_paths" => host_paths,
      "runtime_drivers" => runtime_drivers
    }
  end

  defp normalize_node(_node, _lookup_node_state, _coordination_store), do: nil

  defp stored_node_state(name) do
    case NodeState.fetch(name) do
      {:ok, state} when is_map(state) -> state
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp local_hardware(name) do
    if name == to_string(Node.self()), do: Hardware.info(), else: %{}
  rescue
    _ -> %{}
  end

  def ensure_nodes([]), do: {:error, "no runtime nodes are available"}

  def ensure_nodes(nodes) do
    if Enum.any?(nodes, &Eligibility.schedulable_node?/1) do
      :ok
    else
      {:error, "no schedulable runtime nodes are available"}
    end
  end

  def coordination_store_for_plan(opts, true) do
    case Keyword.get(opts, :coordination_store) do
      coordination_store when is_map(coordination_store) ->
        {:ok, Values.stringify_map(coordination_store)}

      _missing ->
        case RedisStore.coordination_store_status() do
          {:ok, status} -> {:ok, status}
          {:error, reason} -> {:error, "coordination_store_mismatch: #{inspect(reason)}"}
        end
    end
  end

  def coordination_store_for_plan(opts, false) do
    case Keyword.get(opts, :coordination_store) do
      coordination_store when is_map(coordination_store) ->
        {:ok, Values.stringify_map(coordination_store)}

      _missing ->
        {:ok, nil}
    end
  end

  def apply_coordination_store_eligibility(nodes, nil), do: nodes

  def apply_coordination_store_eligibility(nodes, expected) do
    expected_identity = Values.map_get(expected, "identity")

    Enum.map(nodes, fn node ->
      actual = Values.map_get(node, "coordination_store") || %{}

      reason =
        cond do
          expected_identity in [nil, ""] ->
            "local coordination store has no identity"

          Values.map_get(actual, "identity") != expected_identity ->
            "coordination store identity does not match the local runtime"

          Values.map_get(actual, "writable_primary") != true ->
            "coordination store is not a writable primary"

          true ->
            nil
        end

      if reason do
        node
        |> Map.put("scheduling_eligible", false)
        |> Map.put("coordination_store_rejection", reason)
      else
        node
      end
    end)
  end

  def ensure_coordination_store(_nodes, nil), do: :ok

  def ensure_coordination_store(nodes, expected) do
    expected_identity = Values.map_get(expected, "identity")
    writable_primary = Values.map_get(expected, "writable_primary")

    cond do
      expected_identity in [nil, ""] or writable_primary != true ->
        {:error, "coordination_store_mismatch: local Redis is not a writable identified primary"}

      Enum.any?(nodes, &is_nil(Map.get(&1, "coordination_store_rejection"))) ->
        :ok

      true ->
        details =
          nodes
          |> Enum.map(
            &"#{Map.get(&1, "name")}: #{Map.get(&1, "coordination_store_rejection", "unknown")}"
          )
          |> Enum.join("; ")

        {:error, "coordination_store_mismatch: #{details}"}
    end
  end

  defp node_capacity(hardware) do
    hardware = Values.stringify_map(hardware)
    cpu = Values.number_value(get_in(hardware, ["cpu", "logical_processors"])) || 0
    memory = memory_capacity_mb(get_in(hardware, ["memory"]) || %{})
    disk = disk_capacity_mb(get_in(hardware, ["disk"]) || %{})
    gpu = gpu_count(get_in(hardware, ["gpu"]))

    %{
      "cpu_cores" => Float.round(cpu * Resource.limit_ratio(:cpu), 3),
      "memory_mb" => Float.round(memory * Resource.limit_ratio(:memory), 3),
      "disk_mb" => Float.round(disk * Resource.limit_ratio(:disk), 3),
      "gpu_count" => floor(gpu * Resource.limit_ratio(:gpu))
    }
  end

  defp memory_capacity_mb(memory) do
    available = Values.number_value(Values.map_get(memory, "available_mb"))
    total = Values.number_value(Values.map_get(memory, "total_mb"))

    bytes =
      Values.number_value(Values.map_get(memory, "available_bytes")) ||
        Values.number_value(Values.map_get(memory, "total_bytes"))

    cond do
      is_number(available) and available > 0 -> available
      is_number(total) and total > 0 -> total
      is_number(bytes) and bytes > 0 -> bytes / (1024 * 1024)
      true -> 0
    end
  end

  defp disk_capacity_mb(disk) do
    available = Values.number_value(Values.map_get(disk, "available_mb"))
    total = Values.number_value(Values.map_get(disk, "total_mb"))

    bytes =
      Values.number_value(Values.map_get(disk, "available_bytes")) ||
        Values.number_value(Values.map_get(disk, "total_bytes"))

    cond do
      is_number(available) and available > 0 -> available
      is_number(total) and total > 0 -> total
      is_number(bytes) and bytes > 0 -> bytes / (1024 * 1024)
      true -> 0
    end
  end

  defp gpu_count(gpus) when is_list(gpus), do: length(gpus)

  defp gpu_count(gpu) when is_binary(gpu) do
    if unknown_gpu?(gpu), do: 0, else: 1
  end

  defp gpu_count(gpu) when is_map(gpu), do: 1

  defp gpu_count(_gpu), do: 0

  defp unknown_gpu?(gpu) do
    normalized = String.downcase(gpu)

    Enum.any?(["unknown", "none", "unsupported", "not available"], fn marker ->
      String.contains?(normalized, marker)
    end)
  end

  defp truthy?(value) when value in [true, "true", "TRUE", "True", "1", 1, "yes", "on"],
    do: true

  defp truthy?(_value), do: false

  defp eligible_value(nil), do: true

  defp eligible_value(value) when value in [false, "false", "FALSE", "False", "0", 0], do: false

  defp eligible_value(_value), do: true
end
