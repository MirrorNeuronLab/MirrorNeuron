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
      model: cpu_model(),
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
                   "--query-gpu=index,uuid,name,driver_version,utilization.gpu,memory.used,memory.free,memory.total",
                   "--format=csv,noheader,nounits"
                 ]) do
              {output, 0} ->
                parse_nvidia_gpu(output, memory, %{"cuda_version" => nvidia_cuda_version()})

              _ ->
                case linux_pci_gpu_info(memory) do
                  [] -> "Unknown or None"
                  devices -> devices
                end
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
        model: model,
        kind: "gpu",
        type: "apple/gpu",
        vendor: "apple",
        driver: "metal",
        api: "metal",
        api_version: nil,
        driver_version: nil,
        gpu_type: "mac-metal",
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

  defp cpu_model do
    blank_to_nil(System.get_env("MN_NODE_CPU_MODEL")) ||
      case :os.type() do
        {:unix, :darwin} -> darwin_cpu_model()
        {:unix, :linux} -> linux_cpu_model()
        {:win32, _name} -> windows_cpu_model()
        _ -> nil
      end
  rescue
    _ -> nil
  end

  defp darwin_cpu_model do
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"]) do
      {output, 0} -> blank_to_nil(output)
      _ -> nil
    end
  end

  defp linux_cpu_model do
    with {:ok, cpuinfo} <- File.read("/proc/cpuinfo") do
      cpuinfo
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            key = key |> String.trim() |> String.downcase()

            if key in ["model name", "hardware", "processor", "cpu model"] do
              blank_to_nil(value)
            end

          _ ->
            nil
        end
      end)
    else
      _ -> nil
    end
  end

  defp windows_cpu_model do
    case System.cmd("wmic", ["cpu", "get", "Name", "/value"]) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, "=", parts: 2) do
            ["Name", value] -> blank_to_nil(value)
            _ -> nil
          end
        end)

      _ ->
        nil
    end
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

  def parse_nvidia_gpu(output, memory \\ %{}, driver_info \\ %{}) do
    output
    |> String.split("\n", trim: true)
    |> Enum.with_index()
    |> Enum.map(fn line ->
      {line, fallback_index} = line

      columns =
        line
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      {index, uuid, name, driver_version, utilization, memory_used, memory_free, memory_total} =
        case columns do
          [index, uuid, name, driver_version, utilization, memory_used, memory_free, memory_total] ->
            {parse_integer(index) || fallback_index, uuid, name, driver_version, utilization,
             memory_used, memory_free, memory_total}

          [index, uuid, name, utilization, memory_used, memory_free, memory_total] ->
            {parse_integer(index) || fallback_index, uuid, name,
             map_get(driver_info, "driver_version"), utilization, memory_used, memory_free,
             memory_total}

          [name, utilization, memory_used, memory_total] ->
            {fallback_index, nil, name, map_get(driver_info, "driver_version"), utilization,
             memory_used, nil, memory_total}

          _ ->
            {fallback_index, nil, Enum.join(columns, ", "),
             map_get(driver_info, "driver_version"), nil, nil, nil, nil}
        end

      utilization_ratio = utilization |> parse_float() |> ratio(100)
      memory_used_mb = parse_float(memory_used)
      memory_free_mb = parse_float(memory_free)
      memory_total_mb = parse_float(memory_total) || shared_nvidia_memory_total_mb(name, memory)
      shared_memory_free_mb = shared_nvidia_memory_free_mb(name, memory)
      cuda_version = map_get(driver_info, "cuda_version")

      %{
        id: uuid || "nvidia-#{index}",
        index: index,
        name: name,
        model: name,
        kind: "gpu",
        type: "nvidia/gpu",
        vendor: "nvidia",
        driver: "cuda",
        api: "cuda",
        api_version: cuda_version,
        driver_version: blank_to_nil(driver_version),
        gpu_type: gpu_type("nvidia", "cuda", cuda_version),
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

  def parse_lspci_gpu(output, rocm_version \\ nil) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_lspci_gpu_line(&1, rocm_version))
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index()
    |> Enum.map(fn {device, index} -> Map.put(device, :index, index) end)
  end

  defp parse_lspci_gpu_line(line, rocm_version) do
    normalized = String.downcase(line)

    if pci_gpu_line?(normalized) do
      {slot, class, vendor_name, device_name} = parse_lspci_fields(line)
      search_text = String.downcase("#{vendor_name} #{device_name} #{line}")
      vendor = lspci_gpu_vendor(search_text)

      if vendor do
        api_version = if(vendor == "amd", do: rocm_version)
        driver = driver_from_gpu_vendor(vendor)
        api = api_from_gpu_driver(driver)
        name = blank_to_nil("#{vendor_name} #{device_name}") || blank_to_nil(device_name) || line

        %{
          id: "pci-#{slot}",
          name: name,
          model: name,
          kind: "gpu",
          type: type_from_gpu_vendor(vendor),
          vendor: vendor,
          driver: driver,
          api: api,
          api_version: api_version,
          driver_version: nil,
          gpu_type: gpu_type(vendor, api || driver, api_version),
          memory_total_mb: nil,
          memory_free_mb: nil,
          capabilities: configured_gpu_capabilities(vendor, driver, search_text <> " " <> class)
        }
      end
    end
  end

  defp pci_gpu_line?(line) do
    String.contains?(line, "vga compatible controller") or
      String.contains?(line, "3d controller") or
      String.contains?(line, "display controller")
  end

  defp parse_lspci_fields(line) do
    slot = line |> String.split(" ", parts: 2) |> List.first() |> String.trim_trailing(":")

    quoted =
      ~r/"([^"]*)"/
      |> Regex.scan(line, capture: :all_but_first)
      |> Enum.map(&List.first/1)

    case quoted do
      [class, vendor, device | _rest] ->
        {slot, class, vendor, device}

      _ ->
        {before_colon, after_colon} =
          case String.split(line, ":", parts: 2) do
            [before, after_value] -> {before, after_value}
            [before] -> {before, ""}
          end

        class = before_colon |> String.replace(slot, "") |> String.trim()
        {vendor, device} = split_lspci_vendor_device(after_colon)
        {slot, class, vendor, device}
    end
  end

  defp split_lspci_vendor_device(value) do
    value = String.trim(value)

    cond do
      String.match?(value, ~r/advanced micro devices|amd|ati/i) ->
        split_known_vendor(value, ~r/(advanced micro devices[^\[]*|amd|ati)/i)

      String.match?(value, ~r/intel/i) ->
        split_known_vendor(value, ~r/(intel[^\[]*)/i)

      String.match?(value, ~r/nvidia/i) ->
        split_known_vendor(value, ~r/(nvidia[^\[]*)/i)

      true ->
        {"", value}
    end
  end

  defp split_known_vendor(value, regex) do
    case Regex.run(regex, value, return: :index) do
      [{start, length} | _rest] ->
        vendor = value |> String.slice(start, length) |> String.trim()
        device = value |> String.replace(vendor, "", global: false) |> String.trim()
        {vendor, device}

      _ ->
        {"", value}
    end
  end

  defp lspci_gpu_vendor(text) do
    cond do
      String.contains?(text, "nvidia") -> "nvidia"
      String.contains?(text, "advanced micro devices") -> "amd"
      String.contains?(text, "amd") -> "amd"
      Regex.match?(~r/\bati\b|\[amd\/ati\]/, text) -> "amd"
      String.contains?(text, "radeon") -> "amd"
      String.contains?(text, "intel") -> "intel"
      true -> nil
    end
  end

  defp generic_gpu_devices(0, _memory), do: []

  defp generic_gpu_devices(count, memory) when is_integer(count) and count > 0 do
    profile = configured_gpu_profile()

    for index <- 0..(count - 1) do
      %{
        id: "gpu-#{index}",
        index: index,
        name: profile.name || "GPU #{index + 1}",
        model: profile.name || "GPU #{index + 1}",
        kind: "gpu",
        type: profile.type,
        vendor: profile.vendor,
        driver: profile.driver,
        memory_total_mb: number_value(map_get(memory, "total_mb")),
        memory_free_mb: number_value(map_get(memory, "available_mb")),
        api: profile.api,
        api_version: profile.api_version,
        driver_version: profile.driver_version,
        gpu_type: profile.gpu_type,
        capabilities: profile.capabilities
      }
    end
  end

  defp generic_gpu_devices(_count, _memory), do: []

  defp configured_gpu_profile do
    identity =
      [
        System.get_env("MN_NODE_GPU_NAME"),
        System.get_env("MN_NODE_GPU_VENDOR"),
        System.get_env("MN_NODE_GPU_DRIVER"),
        System.get_env("MN_NODE_GPU_TYPE"),
        System.get_env("MN_NODE_GPU_API_VERSION"),
        System.get_env("MN_NODE_GPU_DRIVER_VERSION"),
        System.get_env("MN_NODE_CAPABILITIES"),
        System.get_env("MN_NODE_DISPLAY_NAME")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    normalized = String.downcase(identity)

    vendor =
      normalize_gpu_vendor(System.get_env("MN_NODE_GPU_VENDOR")) ||
        inferred_gpu_vendor(normalized)

    driver =
      normalize_gpu_driver(System.get_env("MN_NODE_GPU_DRIVER")) ||
        driver_from_gpu_vendor(vendor)

    type = System.get_env("MN_NODE_GPU_TYPE") || type_from_gpu_vendor(vendor)
    name = System.get_env("MN_NODE_GPU_NAME") || inferred_gpu_name(vendor, normalized)
    api = api_from_gpu_driver(driver)

    api_version =
      System.get_env("MN_NODE_GPU_API_VERSION") || inferred_api_version(driver, normalized)

    driver_version = System.get_env("MN_NODE_GPU_DRIVER_VERSION")

    %{
      name: name,
      type: type,
      vendor: vendor || "generic",
      driver: driver || "generic",
      api: api,
      api_version: api_version,
      driver_version: driver_version,
      gpu_type: gpu_type(vendor, api || driver, api_version),
      capabilities: configured_gpu_capabilities(vendor, driver, normalized)
    }
  end

  defp configured_gpu_capabilities(vendor, driver, normalized) do
    (["gpu", vendor, driver] ++
       split_env_list(System.get_env("MN_NODE_CAPABILITIES")) ++
       inferred_gpu_capabilities(vendor, normalized))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp inferred_gpu_capabilities("nvidia", normalized),
    do: ["nvidia", "cuda"] ++ nvidia_gpu_capabilities(normalized)

  defp inferred_gpu_capabilities("apple", normalized),
    do: ["apple", "metal", "unified_memory"] ++ apple_gpu_capabilities(normalized)

  defp inferred_gpu_capabilities("amd", _normalized), do: ["amd", "rocm"]
  defp inferred_gpu_capabilities("intel", _normalized), do: ["intel"]
  defp inferred_gpu_capabilities(_vendor, _normalized), do: ["generic"]

  defp inferred_gpu_vendor(normalized) do
    cond do
      String.contains?(normalized, "nvidia") or String.contains?(normalized, "cuda") or
        String.contains?(normalized, "dgx spark") or String.contains?(normalized, "gb10") or
          String.contains?(normalized, "spark") ->
        "nvidia"

      String.contains?(normalized, "apple") or String.contains?(normalized, "metal") or
        String.contains?(normalized, "macbook") or String.contains?(normalized, "mac mini") or
          String.contains?(normalized, "mac studio") ->
        "apple"

      String.contains?(normalized, "amd") or String.contains?(normalized, "radeon") or
          String.contains?(normalized, "rocm") ->
        "amd"

      String.contains?(normalized, "intel") ->
        "intel"

      true ->
        nil
    end
  end

  defp inferred_gpu_name("nvidia", normalized) do
    cond do
      String.contains?(normalized, "dgx spark") or String.contains?(normalized, "spark") ->
        "NVIDIA DGX Spark"

      String.contains?(normalized, "gb10") ->
        "NVIDIA GB10"

      true ->
        nil
    end
  end

  defp inferred_gpu_name("apple", _normalized), do: "Apple Metal GPU"
  defp inferred_gpu_name(_vendor, _normalized), do: nil

  defp normalize_gpu_vendor(nil), do: nil

  defp normalize_gpu_vendor(value) do
    case normalize_capability(value) do
      value when value in ["nvidia", "amd", "apple", "intel"] -> value
      _ -> nil
    end
  end

  defp normalize_gpu_driver(nil), do: nil

  defp normalize_gpu_driver(value) do
    case normalize_capability(value) do
      value when value in ["cuda", "rocm", "metal", "intel", "generic"] -> value
      _ -> nil
    end
  end

  defp driver_from_gpu_vendor("nvidia"), do: "cuda"
  defp driver_from_gpu_vendor("amd"), do: "rocm"
  defp driver_from_gpu_vendor("apple"), do: "metal"
  defp driver_from_gpu_vendor("intel"), do: "intel"
  defp driver_from_gpu_vendor(_vendor), do: "generic"

  defp api_from_gpu_driver("cuda"), do: "cuda"
  defp api_from_gpu_driver("rocm"), do: "rocm"
  defp api_from_gpu_driver("metal"), do: "metal"
  defp api_from_gpu_driver(_driver), do: nil

  defp inferred_api_version(driver, normalized) do
    cond do
      driver == "cuda" -> version_after(normalized, "cuda")
      driver == "rocm" -> version_after(normalized, "rocm")
      true -> nil
    end
  end

  defp gpu_type("nvidia", "cuda", version), do: versioned_type("nvidia-cuda", version)
  defp gpu_type("amd", "rocm", version), do: versioned_type("amd-rocm", version)
  defp gpu_type("apple", "metal", _version), do: "mac-metal"
  defp gpu_type("intel", _api, _version), do: "intel"
  defp gpu_type(_vendor, _api, _version), do: "generic"

  defp versioned_type(prefix, nil), do: prefix
  defp versioned_type(prefix, ""), do: prefix
  defp versioned_type(prefix, version), do: "#{prefix}-#{version}"

  defp type_from_gpu_vendor(nil), do: "generic/gpu"
  defp type_from_gpu_vendor("generic"), do: "generic/gpu"
  defp type_from_gpu_vendor(vendor), do: "#{vendor}/gpu"

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

    drivers = ["host_local"] ++ configured ++ openshell_driver() ++ docker_worker_driver()

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

  defp linux_pci_gpu_info(_memory) do
    case System.cmd("lspci", ["-mm"]) do
      {output, 0} -> parse_lspci_gpu(output, rocm_version())
      _ -> []
    end
  rescue
    _ -> []
  end

  defp advertised_node_capabilities do
    System.get_env("MN_NODE_CAPABILITIES")
    |> split_env_list()
  end

  defp nvidia_cuda_version do
    blank_to_nil(System.get_env("CUDA_VERSION")) ||
      case System.cmd("nvidia-smi", []) do
        {output, 0} ->
          version_after(output, "CUDA Version:")

        _ ->
          nil
      end
  rescue
    _ -> nil
  end

  defp rocm_version do
    blank_to_nil(System.get_env("ROCM_VERSION")) ||
      blank_to_nil(System.get_env("HIP_VERSION")) ||
      rocm_version_file() ||
      case System.cmd("rocminfo", []) do
        {output, 0} ->
          version_after(output, "ROCm Version") ||
            version_after(output, "ROCM Version") ||
            version_after(output, "HSA Runtime Version")

        _ ->
          nil
      end
  rescue
    _ -> nil
  end

  defp rocm_version_file do
    case File.read("/opt/rocm/.info/version") do
      {:ok, value} -> blank_to_nil(value)
      _ -> nil
    end
  end

  defp nvidia_gpu_capabilities(name) do
    normalized = String.downcase(to_string(name || ""))

    []
    |> maybe_capability(
      String.contains?(normalized, "dgx spark") or String.contains?(normalized, "spark"),
      "nvidia-dgx-spark"
    )
    |> maybe_capability(String.contains?(normalized, "gh200"), "nvidia-gh200")
    |> maybe_capability(String.contains?(normalized, "h100"), "nvidia-h100")
    |> maybe_capability(String.contains?(normalized, "h200"), "nvidia-h200")
    |> maybe_capability(String.contains?(normalized, "b200"), "nvidia-b200")
    |> maybe_capability(String.contains?(normalized, "gb10"), "nvidia-gb10")
    |> maybe_capability(String.contains?(normalized, "gb200"), "nvidia-gb200")
  end

  defp shared_nvidia_memory_total_mb(name, memory) do
    if shared_nvidia_memory_gpu?(name), do: number_value(map_get(memory, "total_mb"))
  end

  defp shared_nvidia_memory_free_mb(name, memory) do
    if shared_nvidia_memory_gpu?(name), do: number_value(map_get(memory, "available_mb"))
  end

  defp shared_nvidia_memory_gpu?(name) do
    normalized =
      name
      |> to_string()
      |> String.downcase()

    String.contains?(normalized, "gb10") or String.contains?(normalized, "dgx spark") or
      String.contains?(normalized, "spark")
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

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "" or String.downcase(value) == "[n/a]", do: nil, else: value
  end

  defp version_after(nil, _label), do: nil

  defp version_after(value, label) do
    label = Regex.escape(to_string(label))

    case Regex.run(~r/#{label}\s*[:=\- ]*\s*([0-9]+(?:\.[0-9]+)*)/i, to_string(value)) do
      [_match, version] -> version
      _ -> nil
    end
  end

  defp openshell_driver do
    if System.find_executable("openshell") || System.get_env("OPENSHELL_GATEWAY") do
      ["openshell"]
    else
      []
    end
  end

  defp docker_worker_driver do
    case System.get_env("MN_DOCKER_WORKER_ENABLED") do
      value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] ->
        []

      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] ->
        ["docker_worker"]

      _ ->
        docker_bin = System.get_env("MN_DOCKER_BIN", "docker")
        if System.find_executable(docker_bin), do: ["docker_worker"], else: []
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
