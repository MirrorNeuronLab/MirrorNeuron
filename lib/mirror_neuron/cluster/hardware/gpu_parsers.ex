defmodule MirrorNeuron.Cluster.Hardware.GpuParsers do
  @moduledoc "Parses NVIDIA, Darwin and PCI inventory into canonical device observations."

  alias MirrorNeuron.Cluster.Hardware.GpuProfile
  alias MirrorNeuron.Cluster.Hardware.Values

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
        memory_total_mb: Values.number_value(Values.map_get(memory, "total_mb")),
        memory_free_mb: Values.number_value(Values.map_get(memory, "available_mb")),
        capabilities:
          ["gpu", "apple", "metal", "unified_memory"] ++ GpuProfile.apple_gpu_capabilities(model)
      }
    end)
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
            {Values.parse_integer(index) || fallback_index, uuid, name, driver_version,
             utilization, memory_used, memory_free, memory_total}

          [index, uuid, name, utilization, memory_used, memory_free, memory_total] ->
            {Values.parse_integer(index) || fallback_index, uuid, name,
             Values.map_get(driver_info, "driver_version"), utilization, memory_used, memory_free,
             memory_total}

          [name, utilization, memory_used, memory_total] ->
            {fallback_index, nil, name, Values.map_get(driver_info, "driver_version"),
             utilization, memory_used, nil, memory_total}

          _ ->
            {fallback_index, nil, Enum.join(columns, ", "),
             Values.map_get(driver_info, "driver_version"), nil, nil, nil, nil}
        end

      utilization_ratio = utilization |> Values.parse_float() |> Values.ratio(100)
      memory_used_mb = Values.parse_float(memory_used)
      memory_free_mb = Values.parse_float(memory_free)

      memory_total_mb =
        Values.parse_float(memory_total) || shared_nvidia_memory_total_mb(name, memory)

      shared_memory_free_mb = shared_nvidia_memory_free_mb(name, memory)
      cuda_version = Values.map_get(driver_info, "cuda_version")

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
        driver_version: Values.blank_to_nil(driver_version),
        gpu_type: GpuProfile.gpu_type("nvidia", "cuda", cuda_version),
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
        memory_used_ratio: Values.ratio(memory_used_mb, memory_total_mb),
        capabilities: ["gpu", "nvidia", "cuda"] ++ GpuProfile.nvidia_gpu_capabilities(name)
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
        driver = GpuProfile.driver_from_gpu_vendor(vendor)
        api = GpuProfile.api_from_gpu_driver(driver)

        name =
          Values.blank_to_nil("#{vendor_name} #{device_name}") || Values.blank_to_nil(device_name) ||
            line

        %{
          id: "pci-#{slot}",
          name: name,
          model: name,
          kind: "gpu",
          type: GpuProfile.type_from_gpu_vendor(vendor),
          vendor: vendor,
          driver: driver,
          api: api,
          api_version: api_version,
          driver_version: nil,
          gpu_type: GpuProfile.gpu_type(vendor, api || driver, api_version),
          memory_total_mb: nil,
          memory_free_mb: nil,
          capabilities:
            GpuProfile.configured_gpu_capabilities(vendor, driver, search_text <> " " <> class)
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

  defp shared_nvidia_memory_total_mb(name, memory) do
    if shared_nvidia_memory_gpu?(name),
      do: Values.number_value(Values.map_get(memory, "total_mb"))
  end

  defp shared_nvidia_memory_free_mb(name, memory) do
    if shared_nvidia_memory_gpu?(name),
      do: Values.number_value(Values.map_get(memory, "available_mb"))
  end

  defp shared_nvidia_memory_gpu?(name) do
    normalized =
      name
      |> to_string()
      |> String.downcase()

    String.contains?(normalized, "gb10") or String.contains?(normalized, "dgx spark") or
      String.contains?(normalized, "spark")
  end
end
