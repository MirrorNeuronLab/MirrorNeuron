defmodule MirrorNeuron.ResourceSpec.Requests do
  @moduledoc "Normalizes requested capacity, devices, ports and host volumes."

  alias MirrorNeuron.ResourceSpec.Values

  @resource_keys ["cpu_cores", "memory_mb", "disk_mb", "gpu_count"]

  def resource_keys, do: @resource_keys

  def empty_resources, do: Map.new(@resource_keys, &{&1, 0})

  def normalize_request(resources) when is_map(resources) do
    resources = Values.stringify_map(resources)
    devices = normalize_device_requests(Map.get(resources, "devices", []))
    ports = normalize_ports(Map.get(resources, "ports", []))
    volumes = normalize_volumes(Map.get(resources, "volumes", []))

    scalar = %{
      "cpu_cores" => Values.number_value(Map.get(resources, "cpu_cores")) || 0.0,
      "memory_mb" => Values.number_value(Map.get(resources, "memory_mb")) || 0.0,
      "disk_mb" => Values.number_value(Map.get(resources, "disk_mb")) || 0.0,
      "gpu_count" =>
        Values.number_value(Map.get(resources, "gpu_count")) || gpu_device_count(devices) || 0
    }

    %{
      "resources" => scalar,
      "devices" => devices,
      "ports" => ports,
      "volumes" => volumes,
      "runtime_driver" => Values.blank_to_nil(Map.get(resources, "runtime_driver"))
    }
  end

  def normalize_request(_resources) do
    %{
      "resources" => empty_resources(),
      "devices" => [],
      "ports" => [],
      "volumes" => [],
      "runtime_driver" => nil
    }
  end

  def scalar_resources(resources) when is_map(resources) do
    normalize_request(resources)["resources"]
  end

  def scalar_resources(_resources), do: empty_resources()

  def add_gpu_need(%{"resources" => resources} = spec, count) when is_number(count) do
    next_resources = Map.update(resources, "gpu_count", count, &max(&1 || 0, count))
    Map.put(spec, "resources", next_resources)
  end

  def add_gpu_need(spec, _count), do: spec

  def with_runtime_driver(%{"runtime_driver" => nil} = spec, driver) do
    Map.put(spec, "runtime_driver", Values.blank_to_nil(driver))
  end

  def with_runtime_driver(spec, _driver), do: spec

  def scheduling_devices(%{"devices" => devices, "resources" => resources}) do
    case devices do
      [] ->
        case Values.number_value(Map.get(resources || %{}, "gpu_count")) do
          count when is_number(count) and count > 0 ->
            [%{"kind" => "gpu", "type" => "gpu", "count" => trunc(count)}]

          _ ->
            []
        end

      devices ->
        devices
    end
  end

  def scheduling_devices(_spec), do: []

  defp normalize_device_requests(devices) when is_list(devices) do
    devices
    |> Enum.with_index()
    |> Enum.map(fn {device, index} -> normalize_device_request(device, index) end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_device_requests(nil), do: []

  defp normalize_device_requests(_devices), do: []

  defp normalize_device_request(device, _index) when is_map(device) do
    device = Values.stringify_map(device)
    type = Values.blank_to_nil(Values.map_get(device, "type"))
    kind = Values.blank_to_nil(Values.map_get(device, "kind")) || Values.kind_from_type(type)

    %{
      "kind" => kind || "device",
      "type" => type || kind || "device",
      "count" => trunc(Values.number_value(Values.map_get(device, "count")) || 1),
      "vendor" => Values.blank_to_nil(Values.map_get(device, "vendor")),
      "driver" => Values.blank_to_nil(Values.map_get(device, "driver")),
      "min_memory_mb" => Values.number_value(Values.map_get(device, "min_memory_mb")),
      "memory_operator" =>
        Values.normalize_comparison_operator(Values.map_get(device, "memory_operator")),
      "min_api_version" => Values.trim_to_nil(Values.map_get(device, "min_api_version")),
      "api_version_operator" =>
        Values.normalize_comparison_operator(Values.map_get(device, "api_version_operator")),
      "capabilities" => Values.list_value(Values.map_get(device, "capabilities")),
      "ids" => Values.list_value(Values.map_get(device, "ids"))
    }
  end

  defp normalize_device_request(_device, _index), do: nil

  defp normalize_ports(ports) when is_list(ports) do
    ports
    |> Enum.map(&normalize_port/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_ports(nil), do: []

  defp normalize_ports(_ports), do: []

  defp normalize_port(port) when is_map(port) do
    port = Values.stringify_map(port)
    label = Values.map_get(port, "label")
    port_value = Values.map_get(port, "port")
    number = Values.number_value(port_value)

    if is_nil(label) or (is_nil(number) and not Values.auto_port?(port_value)) do
      nil
    else
      %{
        "label" => to_string(label),
        "port" => if(Values.auto_port?(port_value), do: "auto", else: trunc(number)),
        "protocol" => String.downcase(to_string(Values.map_get(port, "protocol") || "tcp"))
      }
    end
  end

  defp normalize_port(_port), do: nil

  defp normalize_volumes(volumes) when is_list(volumes) do
    volumes
    |> Enum.map(&normalize_volume/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_volumes(nil), do: []

  defp normalize_volumes(_volumes), do: []

  defp normalize_volume(volume) when is_map(volume) do
    volume = Values.stringify_map(volume)
    name = Values.map_get(volume, "name")
    source = Values.map_get(volume, "source")
    target = Values.map_get(volume, "target")

    if is_nil(name) or is_nil(source) or is_nil(target) do
      nil
    else
      %{
        "name" => to_string(name),
        "source" => Path.expand(to_string(source)),
        "target" => to_string(target),
        "mode" => String.downcase(to_string(Values.map_get(volume, "mode") || "ro")),
        "type" => String.downcase(to_string(Values.map_get(volume, "type") || "host"))
      }
    end
  end

  defp normalize_volume(_volume), do: nil

  defp gpu_device_count(devices) do
    count =
      devices
      |> Enum.filter(fn device ->
        String.contains?(String.downcase(to_string(Values.map_get(device, "kind"))), "gpu") or
          String.contains?(String.downcase(to_string(Values.map_get(device, "type"))), "gpu")
      end)
      |> Enum.map(&(Values.number_value(Values.map_get(&1, "count")) || 1))
      |> Enum.sum()

    if count > 0, do: count, else: nil
  end
end
