defmodule MirrorNeuron.Cluster.Hardware do
  @moduledoc """
  Fetches hardware information from the current node.
  """

  alias MirrorNeuron.ResourceSpec

  def info do
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
    hostname = host_name()

    %{
      family: to_string(family),
      os: to_string(name),
      node: to_string(Node.self()),
      hostname: hostname,
      display_name: System.get_env("MN_NODE_DISPLAY_NAME") || hostname
    }
  end

  defp cpu_info do
    logical_processors = :erlang.system_info(:logical_processors)
    load_average_1m = load_average_1m()

    %{
      logical_processors: logical_processors,
      architecture: to_string(:erlang.system_info(:system_architecture)),
      load_average_1m: load_average_1m,
      load_ratio: ratio(load_average_1m, logical_processors)
    }
  end

  defp memory_info do
    case :os.type() do
      {:unix, :darwin} ->
        with {:ok, total_bytes} <- darwin_total_memory(),
             {:ok, available_bytes} <- darwin_available_memory() do
          memory_pressure(total_bytes, available_bytes)
        else
          _ -> %{total_bytes: 0, total_mb: 0}
        end

      {:unix, :linux} ->
        with {:ok, meminfo} <- File.read("/proc/meminfo"),
             {:ok, total_kb} <- meminfo_value(meminfo, "MemTotal"),
             {:ok, available_kb} <- meminfo_value(meminfo, "MemAvailable") do
          memory_pressure(total_kb * 1024, available_kb * 1024)
        else
          _ -> %{total_bytes: 0, total_mb: 0}
        end

      _ ->
        %{total_bytes: 0, total_mb: 0}
    end
  rescue
    _ -> %{total_bytes: 0, total_mb: 0}
  end

  defp gpu_info(memory) do
    case configured_gpu_info(memory) do
      nil ->
        case :os.type() do
          {:unix, :darwin} ->
            case System.cmd("system_profiler", ["SPDisplaysDataType"]) do
              {output, 0} ->
                parse_darwin_gpu(output, memory)

              _ ->
                "Unknown"
            end

          {:unix, :linux} ->
            case System.cmd("nvidia-smi", [
                   "--query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.free,memory.total",
                   "--format=csv,noheader,nounits"
                 ]) do
              {output, 0} ->
                parse_nvidia_gpu(output, memory)

              _ ->
                "Unknown or None"
            end

          _ ->
            "Unsupported"
        end

      configured ->
        configured
    end
  rescue
    _ -> "Not available"
  end

  defp configured_gpu_info(memory) do
    cond do
      count = parse_gpu_count(System.get_env("MN_NODE_GPU_COUNT")) ->
        generic_gpu_devices(count, memory)

      truthy?(System.get_env("MN_NODE_GPU")) ->
        generic_gpu_devices(1, memory)

      falsey?(System.get_env("MN_NODE_GPU")) ->
        []

      true ->
        nil
    end
  end

  defp disk_info do
    case System.cmd("df", ["-k", "."]) do
      {output, 0} ->
        parse_disk_df(output)

      _ ->
        %{total_bytes: 0, total_mb: 0, available_bytes: 0, available_mb: 0}
    end
  rescue
    _ -> %{total_bytes: 0, total_mb: 0, available_bytes: 0, available_mb: 0}
  end

  def parse_darwin_gpu(output, memory \\ %{}) do
    lines = String.split(output, "\n")

    models =
      lines
      |> Enum.filter(&String.contains?(&1, "Chipset Model"))
      |> Enum.map(fn line ->
        line |> String.split(":", parts: 2) |> List.last() |> String.trim()
      end)
      |> Enum.reject(&(&1 == ""))

    models =
      case models do
        [] -> ["Unknown macOS GPU"]
        values -> values
      end

    Enum.with_index(models, fn model, index ->
      %{
        id: "metal-#{index}",
        index: index,
        name: model,
        kind: "gpu",
        type: "apple/gpu",
        vendor: "apple",
        driver: "metal",
        memory_total_mb: number_value(map_get(memory, "total_mb")),
        memory_free_mb: number_value(map_get(memory, "available_mb")),
        capabilities: ["gpu", "apple", "metal", "unified_memory"] ++ apple_gpu_capabilities(model)
      }
    end)
  end

  defp load_average_1m do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("sysctl", ["-n", "vm.loadavg"]) do
          {output, 0} ->
            output
            |> String.replace(["{", "}"], "")
            |> String.split()
            |> List.first()
            |> parse_float()

          _ ->
            nil
        end

      {:unix, :linux} ->
        with {:ok, output} <- File.read("/proc/loadavg") do
          output |> String.split() |> List.first() |> parse_float()
        else
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp darwin_total_memory do
    case System.cmd("sysctl", ["-n", "hw.memsize"]) do
      {output, 0} -> {:ok, String.trim(output) |> String.to_integer()}
      _ -> {:error, :unknown}
    end
  end

  defp darwin_available_memory do
    with {page_size_output, 0} <- System.cmd("sysctl", ["-n", "hw.pagesize"]),
         {vm_stat, 0} <- System.cmd("vm_stat", []),
         page_size <- String.trim(page_size_output) |> String.to_integer(),
         free <- vm_stat_pages(vm_stat, "Pages free"),
         speculative <- vm_stat_pages(vm_stat, "Pages speculative") do
      {:ok, (free + speculative) * page_size}
    else
      _ -> {:error, :unknown}
    end
  end

  defp vm_stat_pages(output, label) do
    output
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      if String.starts_with?(String.trim(line), label) do
        line
        |> String.replace(~r/[^0-9]/, "")
        |> String.to_integer()
      end
    end)
  end

  defp meminfo_value(meminfo, label) do
    case Regex.run(~r/^#{label}:\s+(\d+)\s+kB/m, meminfo) do
      [_, value] -> {:ok, String.to_integer(value)}
      _ -> {:error, :missing}
    end
  end

  defp memory_pressure(total_bytes, available_bytes) do
    used_bytes = max(total_bytes - available_bytes, 0)

    %{
      total_bytes: total_bytes,
      total_mb: Float.round(total_bytes / (1024 * 1024), 2),
      available_bytes: available_bytes,
      available_mb: Float.round(available_bytes / (1024 * 1024), 2),
      used_bytes: used_bytes,
      used_mb: Float.round(used_bytes / (1024 * 1024), 2),
      used_ratio: ratio(used_bytes, total_bytes)
    }
  end

  def parse_nvidia_gpu(output, memory \\ %{}) do
    output
    |> String.split("\n", trim: true)
    |> Enum.with_index()
    |> Enum.map(fn line ->
      {line, fallback_index} = line

      columns =
        line
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      {index, uuid, name, utilization, memory_used, memory_free, memory_total} =
        case columns do
          [index, uuid, name, utilization, memory_used, memory_free, memory_total] ->
            {parse_integer(index) || fallback_index, uuid, name, utilization, memory_used,
             memory_free, memory_total}

          [name, utilization, memory_used, memory_total] ->
            {fallback_index, nil, name, utilization, memory_used, nil, memory_total}

          _ ->
            {fallback_index, nil, Enum.join(columns, ", "), nil, nil, nil, nil}
        end

      utilization_ratio = utilization |> parse_float() |> ratio(100)
      memory_used_mb = parse_float(memory_used)
      memory_free_mb = parse_float(memory_free)
      memory_total_mb = parse_float(memory_total) || shared_nvidia_memory_total_mb(name, memory)
      shared_memory_free_mb = shared_nvidia_memory_free_mb(name, memory)

      %{
        id: uuid || "nvidia-#{index}",
        index: index,
        name: name,
        kind: "gpu",
        type: "nvidia/gpu",
        vendor: "nvidia",
        driver: "cuda",
        utilization_ratio: utilization_ratio,
        memory_used_mb: memory_used_mb,
        memory_free_mb:
          memory_free_mb ||
            shared_memory_free_mb ||
            if(is_number(memory_total_mb) and is_number(memory_used_mb),
              do: max(memory_total_mb - memory_used_mb, 0),
              else: nil
            ),
        memory_total_mb: memory_total_mb,
        memory_used_ratio: ratio(memory_used_mb, memory_total_mb),
        capabilities: ["gpu", "nvidia", "cuda"] ++ nvidia_gpu_capabilities(name)
      }
    end)
  rescue
    _ -> String.split(output, "\n", trim: true)
  end

  defp generic_gpu_devices(0, _memory), do: []

  defp generic_gpu_devices(count, memory) when is_integer(count) and count > 0 do
    for index <- 0..(count - 1) do
      %{
        id: "gpu-#{index}",
        index: index,
        name: "GPU #{index + 1}",
        kind: "gpu",
        type: "generic/gpu",
        vendor: "generic",
        driver: "generic",
        memory_total_mb: number_value(map_get(memory, "total_mb")),
        memory_free_mb: number_value(map_get(memory, "available_mb")),
        capabilities: ["gpu"]
      }
    end
  end

  defp generic_gpu_devices(_count, _memory), do: []

  defp advertised_host_paths do
    System.get_env("MN_NODE_HOST_PATHS")
    |> split_env_list()
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp advertised_runtime_drivers do
    configured =
      System.get_env("MN_NODE_RUNTIME_DRIVERS")
      |> split_env_list()
      |> Enum.map(&String.downcase/1)

    drivers = ["host_local"] ++ configured ++ openshell_driver()

    drivers
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp hardware_capabilities(gpu, devices) do
    device_caps =
      devices
      |> List.wrap()
      |> Enum.flat_map(&(map_get(&1, "capabilities") |> List.wrap()))

    gpu_caps =
      gpu
      |> List.wrap()
      |> Enum.flat_map(fn
        device when is_map(device) -> map_get(device, "capabilities") |> List.wrap()
        _device -> []
      end)

    (device_caps ++ gpu_caps ++ advertised_node_capabilities())
    |> Enum.map(&normalize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp advertised_node_capabilities do
    System.get_env("MN_NODE_CAPABILITIES")
    |> split_env_list()
  end

  defp nvidia_gpu_capabilities(name) do
    normalized = String.downcase(to_string(name || ""))

    []
    |> maybe_capability(String.contains?(normalized, "dgx spark"), "nvidia-dgx-spark")
    |> maybe_capability(String.contains?(normalized, "gh200"), "nvidia-gh200")
    |> maybe_capability(String.contains?(normalized, "h100"), "nvidia-h100")
    |> maybe_capability(String.contains?(normalized, "h200"), "nvidia-h200")
    |> maybe_capability(String.contains?(normalized, "b200"), "nvidia-b200")
    |> maybe_capability(String.contains?(normalized, "gb10"), "nvidia-gb10")
    |> maybe_capability(String.contains?(normalized, "gb200"), "nvidia-gb200")
  end

  defp shared_nvidia_memory_total_mb(name, memory) do
    if gb10_gpu?(name), do: number_value(map_get(memory, "total_mb"))
  end

  defp shared_nvidia_memory_free_mb(name, memory) do
    if gb10_gpu?(name), do: number_value(map_get(memory, "available_mb"))
  end

  defp gb10_gpu?(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.contains?("gb10")
  end

  defp apple_gpu_capabilities(name) do
    normalized = String.downcase(to_string(name || ""))

    []
    |> maybe_capability(String.contains?(normalized, "m1"), "apple-m1")
    |> maybe_capability(String.contains?(normalized, "m2"), "apple-m2")
    |> maybe_capability(String.contains?(normalized, "m3"), "apple-m3")
    |> maybe_capability(String.contains?(normalized, "m4"), "apple-m4")
    |> maybe_capability(String.contains?(normalized, "max"), "apple-max")
    |> maybe_capability(String.contains?(normalized, "ultra"), "apple-ultra")
  end

  defp maybe_capability(capabilities, true, capability), do: [capability | capabilities]
  defp maybe_capability(capabilities, false, _capability), do: capabilities

  defp normalize_capability(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp openshell_driver do
    if System.find_executable("openshell") || System.get_env("OPENSHELL_GATEWAY") do
      ["openshell"]
    else
      []
    end
  end

  defp split_env_list(nil), do: []

  defp split_env_list(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_disk_df(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> List.first()
    |> case do
      nil ->
        %{total_bytes: 0, total_mb: 0, available_bytes: 0, available_mb: 0}

      line ->
        columns = String.split(line, ~r/\s+/, trim: true)
        total_kb = columns |> Enum.at(1) |> parse_float() || 0
        available_kb = columns |> Enum.at(3) |> parse_float() || 0

        %{
          total_bytes: trunc(total_kb * 1024),
          total_mb: Float.round(total_kb / 1024, 2),
          available_bytes: trunc(available_kb * 1024),
          available_mb: Float.round(available_kb / 1024, 2)
        }
    end
  end

  defp parse_float(nil), do: nil

  defp parse_float(value) do
    case Float.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_gpu_count(nil), do: nil

  defp parse_gpu_count(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {count, ""} when count >= 0 -> count
      _ -> nil
    end
  end

  defp truthy?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false

  defp falsey?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["0", "false", "no", "off"]

  defp falsey?(_value), do: false

  defp host_name do
    case :inet.gethostname() do
      {:ok, hostname} -> hostname |> to_string() |> String.split(".", parts: 2) |> List.first()
      _ -> "unknown-host"
    end
  end

  defp number_value(value) when is_integer(value), do: value
  defp number_value(value) when is_float(value), do: value
  defp number_value(value) when is_binary(value), do: parse_float(value)
  defp number_value(_value), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp map_get(_map, _key), do: nil

  defp ratio(nil, _denominator), do: nil
  defp ratio(_numerator, nil), do: nil
  defp ratio(_numerator, 0), do: nil

  defp ratio(numerator, denominator) when is_number(numerator) and is_number(denominator) do
    Float.round(numerator / denominator, 4)
  end
end
