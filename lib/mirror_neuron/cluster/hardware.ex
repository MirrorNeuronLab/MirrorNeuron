defmodule MirrorNeuron.Cluster.Hardware do
  @moduledoc """
  Fetches hardware information from the current node.
  """

  def info do
    %{
      cpu: cpu_info(),
      memory: memory_info(),
      gpu: gpu_info()
    }
  end

  defp cpu_info do
    %{
      logical_processors: :erlang.system_info(:logical_processors),
      architecture: to_string(:erlang.system_info(:system_architecture))
    }
  end

  defp memory_info do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("sysctl", ["-n", "hw.memsize"]) do
          {output, 0} ->
            bytes = String.trim(output) |> String.to_integer()
            %{total_bytes: bytes, total_mb: Float.round(bytes / (1024 * 1024), 2)}

          _ ->
            %{total_bytes: 0, total_mb: 0}
        end

      {:unix, :linux} ->
        case System.cmd("awk", ["/MemTotal/ {print $2}", "/proc/meminfo"]) do
          {output, 0} ->
            kb = String.trim(output) |> String.to_integer()
            bytes = kb * 1024
            %{total_bytes: bytes, total_mb: Float.round(bytes / (1024 * 1024), 2)}

          _ ->
            %{total_bytes: 0, total_mb: 0}
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
        case System.cmd("nvidia-smi", ["--query-gpu=name,memory.total", "--format=csv,noheader"]) do
          {output, 0} ->
            String.split(output, "\n", trim: true)

          _ ->
            "Unknown or None"
        end

      _ ->
        "Unsupported"
    end
  rescue
    _ -> "Not available"
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
end
