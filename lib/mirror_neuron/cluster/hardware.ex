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

    %{
      platform: platform,
      cpu: cpu,
      memory: memory,
      gpu: gpu,
      devices: ResourceSpec.normalize_node_devices(%{"gpu" => gpu}),
      disk: disk_info(),
      host_paths: advertised_host_paths(),
      runtime_drivers: advertised_runtime_drivers()
    }
  end

  defp platform_info do
    {family, name} = :os.type()

    %{
      family: to_string(family),
      os: to_string(name),
      node: to_string(Node.self())
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
            parse_nvidia_gpu(output)

          _ ->
            "Unknown or None"
        end

      _ ->
        "Unsupported"
    end
  rescue
    _ -> "Not available"
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
        capabilities: ["gpu", "apple", "metal", "unified_memory"]
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

  def parse_nvidia_gpu(output) do
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
      memory_total_mb = parse_float(memory_total)

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
            if(is_number(memory_total_mb) and is_number(memory_used_mb),
              do: max(memory_total_mb - memory_used_mb, 0),
              else: nil
            ),
        memory_total_mb: memory_total_mb,
        memory_used_ratio: ratio(memory_used_mb, memory_total_mb),
        capabilities: ["gpu", "nvidia", "cuda"]
      }
    end)
  rescue
    _ -> String.split(output, "\n", trim: true)
  end

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
