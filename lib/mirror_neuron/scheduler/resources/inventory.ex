defmodule MirrorNeuron.ResourceSpec.Inventory do
  @moduledoc "Normalizes owner device inventory, host paths and runtime drivers."

  alias MirrorNeuron.ResourceSpec.Values

  def normalize_node_devices(hardware_or_node) when is_map(hardware_or_node) do
    hardware = Values.map_get(hardware_or_node, "hardware") || hardware_or_node

    explicit =
      Values.map_get(hardware_or_node, "devices") ||
        Values.map_get(hardware, "devices") ||
        []

    gpu = Values.map_get(hardware, "gpu")

    devices =
      explicit
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {device, index} -> normalize_device_record(device, index) end)
      |> Enum.reject(&is_nil/1)

    gpu_devices =
      gpu
      |> gpu_records()
      |> Enum.with_index()
      |> Enum.map(fn {device, index} -> normalize_device_record(device, index) end)
      |> Enum.reject(&is_nil/1)

    (devices ++ gpu_devices)
    |> Enum.uniq_by(& &1["id"])
  end

  def normalize_node_devices(_hardware), do: []

  def normalize_node_host_paths(node, hardware \\ %{}) do
    node_paths =
      Values.map_get(node, "host_paths") ||
        Values.map_get(node, "volumes") ||
        Values.map_get(node, "volume_paths")

    hardware_paths =
      Values.map_get(hardware || %{}, "host_paths") ||
        Values.map_get(hardware || %{}, "volume_paths")

    (Values.list_value(node_paths) ++ Values.list_value(hardware_paths))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  def normalize_node_runtime_drivers(node, hardware \\ %{}) do
    drivers =
      Values.list_value(Values.map_get(node, "runtime_drivers")) ++
        Values.list_value(Values.map_get(hardware || %{}, "runtime_drivers"))

    case drivers |> Enum.map(&String.downcase/1) |> Enum.uniq() do
      [] -> ["host_local"]
      values -> values
    end
  end

  defp normalize_device_record(device, index) when is_map(device) do
    device = Values.stringify_map(device)

    kind =
      Values.blank_to_nil(Values.map_get(device, "kind")) ||
        Values.kind_from_type(Values.map_get(device, "type")) || "gpu"

    vendor = Values.blank_to_nil(Values.map_get(device, "vendor")) || vendor_from_device(device)
    driver = Values.blank_to_nil(Values.map_get(device, "driver")) || driver_from_vendor(vendor)

    id =
      Values.trim_to_nil(Values.map_get(device, "id")) ||
        Values.trim_to_nil(Values.map_get(device, "uuid")) ||
        "#{kind}-#{index}"

    total =
      Values.number_value(
        Values.map_get(device, "memory_total_mb") || Values.map_get(device, "memory_mb")
      )

    free = Values.number_value(Values.map_get(device, "memory_free_mb"))
    used = Values.number_value(Values.map_get(device, "memory_used_mb"))

    free =
      cond do
        is_number(free) -> free
        is_number(total) and is_number(used) -> max(total - used, 0)
        true -> nil
      end

    capabilities =
      (Values.list_value(Values.map_get(device, "capabilities")) ++ [kind, vendor, driver])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{
      "id" => to_string(id),
      "index" => Values.integer_value(Values.map_get(device, "index")) || index,
      "name" => Values.map_get(device, "name") || "#{kind}-#{index}",
      "model" =>
        Values.trim_to_nil(Values.map_get(device, "model") || Values.map_get(device, "name")),
      "kind" => kind,
      "type" => Values.map_get(device, "type") || type_from_vendor_kind(vendor, kind),
      "vendor" => vendor,
      "driver" => driver,
      "api" => Values.blank_to_nil(Values.map_get(device, "api")),
      "api_version" => Values.trim_to_nil(Values.map_get(device, "api_version")),
      "driver_version" => Values.trim_to_nil(Values.map_get(device, "driver_version")),
      "gpu_type" => Values.trim_to_nil(Values.map_get(device, "gpu_type")),
      "memory_total_mb" => total,
      "memory_free_mb" => free,
      "memory_used_mb" => used,
      "utilization_ratio" => Values.number_value(Values.map_get(device, "utilization_ratio")),
      "memory_used_ratio" => Values.number_value(Values.map_get(device, "memory_used_ratio")),
      "capabilities" => capabilities
    }
  end

  defp normalize_device_record(device, index) when is_binary(device) do
    if unknown_gpu?(device) do
      nil
    else
      %{
        "id" => "gpu-#{index}",
        "index" => index,
        "name" => device,
        "model" => device,
        "kind" => "gpu",
        "type" => "gpu",
        "vendor" => nil,
        "driver" => nil,
        "api" => nil,
        "api_version" => nil,
        "driver_version" => nil,
        "gpu_type" => nil,
        "memory_total_mb" => nil,
        "memory_free_mb" => nil,
        "memory_used_mb" => nil,
        "utilization_ratio" => nil,
        "memory_used_ratio" => nil,
        "capabilities" => ["gpu"]
      }
    end
  end

  defp normalize_device_record(_device, _index), do: nil

  defp gpu_records(gpus) when is_list(gpus), do: gpus

  defp gpu_records(gpu) when is_map(gpu), do: [gpu]

  defp gpu_records(gpu) when is_binary(gpu), do: if(unknown_gpu?(gpu), do: [], else: [gpu])

  defp gpu_records(_gpu), do: []

  defp type_from_vendor_kind(nil, kind), do: kind

  defp type_from_vendor_kind(vendor, kind), do: "#{vendor}/#{kind}"

  defp vendor_from_device(device) do
    name =
      String.downcase(
        to_string(Values.map_get(device, "name") || Values.map_get(device, "type") || "")
      )

    cond do
      String.contains?(name, "nvidia") -> "nvidia"
      String.contains?(name, "amd") or String.contains?(name, "radeon") -> "amd"
      String.contains?(name, "apple") or String.contains?(name, "metal") -> "apple"
      true -> nil
    end
  end

  defp driver_from_vendor("nvidia"), do: "cuda"

  defp driver_from_vendor("amd"), do: "rocm"

  defp driver_from_vendor("apple"), do: "metal"

  defp driver_from_vendor(_vendor), do: nil

  defp unknown_gpu?(gpu) do
    normalized = String.downcase(to_string(gpu))

    Enum.any?(["unknown", "none", "unsupported", "not available"], fn marker ->
      String.contains?(normalized, marker)
    end)
  end
end
