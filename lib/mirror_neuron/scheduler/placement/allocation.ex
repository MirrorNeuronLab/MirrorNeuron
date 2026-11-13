defmodule MirrorNeuron.Scheduler.Placement.Allocation do
  @moduledoc "Fits scalar resources, drivers, ports, volumes and devices for one worker."

  alias MirrorNeuron.Config
  alias MirrorNeuron.HardwareRequirements
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Scheduler.Placement.Usage

  @resource_keys ResourceSpec.resource_keys()

  def capacity_available?(node, used, ask) do
    capacity = node["capacity"] || Usage.empty_resources()
    used_resources = Usage.normalize_usage(used)["resources"]

    Enum.all?(@resource_keys, fn key ->
      required =
        if key == "gpu_count" and Map.get(used, "share_devices", false),
          do: max(Map.get(used_resources, key, 0), Map.get(ask, key, 0)),
          else: Map.get(used_resources, key, 0) + Map.get(ask, key, 0)

      required <= Map.get(capacity, key, 0)
    end)
  end

  def fit_allocation(node, used, demand) do
    used = Usage.normalize_usage(used)

    resource_request =
      Map.get(demand, "resource_request") || %{"resources" => demand["resources"]}

    with :ok <- scalar_capacity_available(node, used, demand["resources"]),
         {:ok, runtime_driver} <- allocate_runtime_driver(node, resource_request),
         {:ok, ports} <- allocate_ports(resource_request, used),
         {:ok, volumes} <- allocate_volumes(node, resource_request),
         {:ok, devices} <- allocate_devices(node, used, resource_request) do
      {:ok,
       %{
         "devices" => devices,
         "ports" => ports,
         "volumes" => volumes,
         "runtime_driver" => runtime_driver
       }}
    end
  end

  defp scalar_capacity_available(node, used, ask) do
    if capacity_available?(node, used, ask || Usage.empty_resources()) do
      :ok
    else
      {:error, :insufficient_resources}
    end
  end

  defp allocate_runtime_driver(node, %{"runtime_driver" => driver})
       when is_binary(driver) and driver != "" do
    if driver in Map.get(node, "runtime_drivers", []) do
      {:ok, driver}
    else
      {:error, :runtime_driver_unavailable}
    end
  end

  defp allocate_runtime_driver(_node, _resource_request), do: {:ok, nil}

  defp allocate_ports(%{"ports" => ports}, used) when is_list(ports) do
    Enum.reduce_while(ports, {:ok, [], used["ports"]}, fn request, {:ok, allocated, reserved} ->
      case allocate_port(request, reserved) do
        {:ok, resolved, key} ->
          {:cont, {:ok, allocated ++ [resolved], MapSet.put(reserved, key)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, allocated, _reserved} -> {:ok, allocated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allocate_ports(_resource_request, _used), do: {:ok, []}

  defp allocate_port(%{"port" => "auto"} = request, reserved) do
    case Enum.find(auto_port_range(), fn port ->
           not MapSet.member?(reserved, Usage.port_key(Map.put(request, "port", port)))
         end) do
      nil ->
        {:error, :port_unavailable}

      port ->
        resolved = Map.put(request, "port", port)
        {:ok, resolved, Usage.port_key(resolved)}
    end
  end

  defp allocate_port(request, reserved) do
    case Usage.port_key(request) do
      nil ->
        {:error, :invalid_port_request}

      key ->
        if MapSet.member?(reserved, key) do
          {:error, :port_conflict}
        else
          {:ok, request, key}
        end
    end
  end

  defp auto_port_range do
    first = Config.integer("MN_AUTO_PORT_START", :auto_port_start)
    last = Config.integer("MN_AUTO_PORT_END", :auto_port_end)

    if first in 1..65_535 and last in first..65_535 do
      first..last
    else
      raise ArgumentError,
            "MN_AUTO_PORT_START and MN_AUTO_PORT_END must define an ascending range within 1..65535"
    end
  end

  defp allocate_volumes(node, %{"volumes" => volumes}) when is_list(volumes) do
    host_paths = Map.get(node, "host_paths", [])

    if Enum.all?(volumes, &volume_available?(&1, host_paths, node["name"])) do
      {:ok, volumes}
    else
      {:error, :volume_unavailable}
    end
  end

  defp allocate_volumes(_node, _resource_request), do: {:ok, []}

  defp allocate_devices(node, used, resource_request) do
    requests = ResourceSpec.scheduling_devices(resource_request)
    devices = Map.get(node, "devices", [])

    used_device_ids =
      if Map.get(used, "share_devices", false), do: MapSet.new(), else: used["devices"]

    Enum.reduce_while(requests, {:ok, [], used_device_ids}, fn request,
                                                               {:ok, selected, used_ids} ->
      available =
        devices
        |> Enum.reject(&(Map.get(&1, "id") in used_ids))
        |> Enum.filter(&device_matches?(&1, request))
        |> Enum.sort_by(&device_sort_key(&1, request))

      count = trunc(Map.get(request, "count", 1) || 1)
      picked = Enum.take(available, count)

      if length(picked) == count do
        next_used = MapSet.union(used_ids, Usage.allocated_device_ids(%{"devices" => picked}))
        {:cont, {:ok, selected ++ picked, next_used}}
      else
        {:halt, {:error, :device_unavailable}}
      end
    end)
    |> case do
      {:ok, devices, _used_ids} -> {:ok, devices}
      {:error, reason} -> {:error, reason}
    end
  end

  def device_matches?(device, request) do
    kind = String.downcase(to_string(Map.get(request, "kind") || ""))
    request_type = String.downcase(to_string(Map.get(request, "type") || ""))
    request_vendor = Map.get(request, "vendor")
    request_driver = Map.get(request, "driver")
    request_type_vendor = vendor_from_type(request_type)
    request_capabilities = Map.get(request, "capabilities", [])
    request_ids = Map.get(request, "ids", [])
    min_memory = Map.get(request, "min_memory_mb")
    memory_operator = Map.get(request, "memory_operator") || ">="
    min_api_version = Map.get(request, "min_api_version")
    api_version_operator = Map.get(request, "api_version_operator") || ">="

    device_kind = String.downcase(to_string(Map.get(device, "kind") || ""))
    device_type = String.downcase(to_string(Map.get(device, "type") || ""))
    device_vendor = Map.get(device, "vendor")
    device_driver = Map.get(device, "driver")
    device_capabilities = Map.get(device, "capabilities", [])
    device_id = to_string(Map.get(device, "id"))
    device_memory = Map.get(device, "memory_free_mb") || Map.get(device, "memory_total_mb")

    Enum.all?([
      kind == "" or kind == device_kind or kind in device_capabilities,
      request_type in ["", "device"] or
        request_type == device_type or
        (String.contains?(request_type, "gpu") and
           (device_kind == "gpu" or "gpu" in device_capabilities)),
      request_type_vendor in [nil, ""] or is_nil(device_vendor) or
        request_type_vendor == device_vendor,
      request_vendor in [nil, ""] or request_vendor == device_vendor,
      request_driver in [nil, ""] or request_driver == device_driver,
      request_ids == [] or device_id in Enum.map(request_ids, &to_string/1),
      Enum.all?(request_capabilities, &(String.downcase(to_string(&1)) in device_capabilities)),
      HardwareRequirements.memory_matches?(device_memory, min_memory, memory_operator),
      HardwareRequirements.version_matches?(
        Map.get(device, "api_version"),
        min_api_version,
        api_version_operator
      )
    ])
  end

  defp device_sort_key(device, request) do
    min_memory = Map.get(request, "min_memory_mb")
    memory = Map.get(device, "memory_free_mb") || Map.get(device, "memory_total_mb") || 0

    if is_number(min_memory) do
      {memory - min_memory, memory}
    else
      {memory, to_string(Map.get(device, "id"))}
    end
  end

  defp vendor_from_type(type) do
    case String.split(to_string(type), "/", parts: 2) do
      [vendor, "gpu"] when vendor not in ["", "gpu", "device"] -> vendor
      _ -> nil
    end
  end

  defp volume_available?(%{"source" => source}, host_paths, _node_name) do
    source = Path.expand(to_string(source))

    Enum.any?(host_paths, fn host_path ->
      source == host_path or String.starts_with?(source, host_path <> "/")
    end)
  end

  defp volume_available?(_volume, _host_paths, _node_name), do: false

  def empty_allocation do
    %{"devices" => [], "ports" => [], "volumes" => [], "runtime_driver" => nil}
  end
end
