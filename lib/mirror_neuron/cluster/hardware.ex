defmodule MirrorNeuron.Cluster.Hardware do
  @moduledoc """
  Fetches hardware information from the current node.
  """

  def info do
    %{
      cpu: cpu_info(),
      memory: memory_info(),
      gpu: gpu_info(),
      disk: disk_info()
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

  defp gpu_info do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("system_profiler", ["SPDisplaysDataType"]) do
          {output, 0} ->
            parse_darwin_gpu(output)

          _ ->
            "Unknown"
        end

      {:unix, :linux} ->
        case System.cmd("nvidia-smi", [
               "--query-gpu=name,utilization.gpu,memory.used,memory.total",
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

  defp parse_darwin_gpu(output) do
    # Simple extraction of Chipset Model
    lines = String.split(output, "\n")
    model_line = Enum.find(lines, &String.contains?(&1, "Chipset Model"))

    if model_line do
      model_line |> String.split(":") |> List.last() |> String.trim()
    else
      "Unknown macOS GPU"
    end
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

  defp parse_nvidia_gpu(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, utilization, memory_used, memory_total] =
        line
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      utilization_ratio = utilization |> parse_float() |> ratio(100)
      memory_used_mb = parse_float(memory_used)
      memory_total_mb = parse_float(memory_total)

      %{
        name: name,
        utilization_ratio: utilization_ratio,
        memory_used_mb: memory_used_mb,
        memory_total_mb: memory_total_mb,
        memory_used_ratio: ratio(memory_used_mb, memory_total_mb)
      }
    end)
  rescue
    _ -> String.split(output, "\n", trim: true)
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

  defp ratio(nil, _denominator), do: nil
  defp ratio(_numerator, nil), do: nil
  defp ratio(_numerator, 0), do: nil

  defp ratio(numerator, denominator) when is_number(numerator) and is_number(denominator) do
    Float.round(numerator / denominator, 4)
  end
end
