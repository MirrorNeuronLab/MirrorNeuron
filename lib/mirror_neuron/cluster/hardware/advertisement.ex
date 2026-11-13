defmodule MirrorNeuron.Cluster.Hardware.Advertisement do
  @moduledoc "Builds hardware identity from operator and native SDK environment declarations."

  alias MirrorNeuron.Config
  alias MirrorNeuron.Cluster.Hardware.GpuProfile
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Cluster.Hardware.Values

  def runtime_advertisement_info do
    platform = platform_info()
    cpu = cpu_info()
    memory = memory_info()
    gpu = gpu_info(memory)
    devices = ResourceSpec.normalize_node_devices(%{"gpu" => gpu})
    capabilities = hardware_capabilities(gpu, devices)

    %{
      platform: platform,
      cpu: cpu,
      memory: memory,
      gpu: gpu,
      devices: devices,
      capabilities: capabilities,
      disk: disk_info(),
      host_paths: advertised_host_paths(),
      runtime_drivers: advertised_runtime_drivers()
    }
  end

  defp platform_info do
    {family, name} = :os.type()
    hostname = Values.host_name()

    %{
      family: to_string(family),
      os: to_string(name),
      node: to_string(Node.self()),
      hostname: hostname,
      display_name: Config.optional_string("MN_NODE_DISPLAY_NAME", :node_display_name) || hostname
    }
  end

  defp cpu_info do
    logical_processors =
      configured_integer("MN_NODE_CPU_CORES") ||
        configured_integer("MN_NODE_LOGICAL_PROCESSORS") ||
        :erlang.system_info(:logical_processors)

    %{
      logical_processors: logical_processors,
      architecture: to_string(:erlang.system_info(:system_architecture)),
      model: Values.cpu_model(),
      load_average_1m: configured_float("MN_NODE_CPU_LOAD_AVERAGE_1M"),
      load_ratio: configured_float("MN_NODE_CPU_LOAD_RATIO")
    }
  end

  defp memory_info do
    total_mb = configured_float("MN_NODE_MEMORY_TOTAL_MB") || 0
    available_mb = configured_float("MN_NODE_MEMORY_AVAILABLE_MB") || total_mb
    Values.memory_pressure(trunc(total_mb * 1024 * 1024), trunc(available_mb * 1024 * 1024))
  rescue
    _ -> %{total_bytes: 0, total_mb: 0}
  end

  defp gpu_info(memory) do
    configured_gpu_info(memory) || []
  rescue
    _ -> "Not available"
  end

  defp configured_gpu_info(memory) do
    cond do
      count = Values.parse_gpu_count(Config.optional_string("MN_NODE_GPU_COUNT", :node_gpu_count)) ->
        GpuProfile.generic_gpu_devices(count, memory)

      Values.truthy?(Config.optional_string("MN_NODE_GPU", :node_gpu)) ->
        GpuProfile.generic_gpu_devices(1, memory)

      Values.falsey?(Config.optional_string("MN_NODE_GPU", :node_gpu)) ->
        []

      true ->
        nil
    end
  end

  defp disk_info do
    total_mb = configured_float("MN_NODE_DISK_TOTAL_MB") || 0
    available_mb = configured_float("MN_NODE_DISK_AVAILABLE_MB") || total_mb

    %{
      total_bytes: trunc(total_mb * 1024 * 1024),
      total_mb: total_mb,
      available_bytes: trunc(available_mb * 1024 * 1024),
      available_mb: available_mb
    }
  rescue
    _ -> %{total_bytes: 0, total_mb: 0, available_bytes: 0, available_mb: 0}
  end

  defp advertised_host_paths do
    "MN_NODE_HOST_PATHS"
    |> Config.list(:node_host_paths)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp advertised_runtime_drivers do
    configured =
      "MN_NODE_RUNTIME_DRIVERS"
      |> Config.list(:node_runtime_drivers)
      |> Enum.map(&String.downcase/1)

    drivers = ["host_local"] ++ configured ++ openshell_driver() ++ docker_worker_driver()

    drivers
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp hardware_capabilities(gpu, devices) do
    device_caps =
      devices
      |> List.wrap()
      |> Enum.flat_map(&(Values.map_get(&1, "capabilities") |> List.wrap()))

    gpu_caps =
      gpu
      |> List.wrap()
      |> Enum.flat_map(fn
        device when is_map(device) -> Values.map_get(device, "capabilities") |> List.wrap()
        _device -> []
      end)

    (device_caps ++ gpu_caps ++ advertised_node_capabilities())
    |> Enum.map(&Values.normalize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp advertised_node_capabilities do
    Config.list("MN_NODE_CAPABILITIES", :node_capabilities)
  end

  defp openshell_driver do
    if System.get_env("OPENSHELL_GATEWAY") do
      ["openshell"]
    else
      []
    end
  end

  defp docker_worker_driver do
    case Config.optional_string("MN_DOCKER_WORKER_ENABLED", :docker_worker_enabled) do
      value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] ->
        []

      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] ->
        ["docker_worker"]

      _ ->
        []
    end
  end

  defp configured_integer(env) do
    case System.get_env(env) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp configured_float(env) do
    case System.get_env(env) do
      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {float, ""} -> float
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
