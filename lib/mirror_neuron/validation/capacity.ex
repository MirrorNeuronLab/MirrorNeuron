defmodule MirrorNeuron.BlueprintValidation.Capacity do
  @moduledoc "Reads aggregate hardware capacity and normalizes requirement units."

  alias MirrorNeuron.BlueprintValidation.Values

  def capacity(snapshot) do
    snapshot = Values.map_value(snapshot)

    {cpu, gpu, memory, disk} =
      case Values.map_get(snapshot, "nodes") do
        nodes when is_list(nodes) ->
          {
            Enum.sum(Enum.map(nodes, &node_cpu_count/1)),
            Enum.sum(Enum.map(nodes, &node_gpu_count/1)),
            Enum.sum(Enum.map(nodes, &node_memory_gb/1)),
            Enum.sum(Enum.map(nodes, &node_disk_gb/1))
          }

        _nodes ->
          {
            number_or_zero(Values.path_get(snapshot, "cpu.logical_processors")),
            gpu_count(Values.map_get(snapshot, "gpu")),
            memory_gb(Values.map_get(snapshot, "memory")),
            disk_available_gb(Values.map_get(snapshot, "disk"))
          }
      end

    %{
      cpu_cores: floor_number(cpu),
      gpu_count: floor_number(gpu),
      memory_gb: Float.round(memory * 1.0, 2),
      disk_gb: Float.round(disk * 1.0, 2)
    }
  end

  def min_value(requirements, key) do
    requirements
    |> Values.map_get(key)
    |> requirement_value(key)
  end

  def min_size_gb(requirements, key) do
    value = Values.map_get(requirements, key)

    cond do
      is_map(value) and not is_nil(Values.map_get(value, "min_gb")) ->
        numeric(Values.map_get(value, "min_gb"))

      is_map(value) and not is_nil(Values.map_get(value, "gb")) ->
        numeric(Values.map_get(value, "gb"))

      is_map(value) and not is_nil(Values.map_get(value, "min_mb")) ->
        number_or_zero(Values.map_get(value, "min_mb")) / 1024

      is_map(value) and not is_nil(Values.map_get(value, "mb")) ->
        number_or_zero(Values.map_get(value, "mb")) / 1024

      is_map(value) ->
        numeric(Values.map_get(value, "min"))

      true ->
        parse_size_gb(value)
    end
  end

  defp requirement_value(nil, _key), do: nil

  defp requirement_value(value, key) when is_map(value) do
    keys =
      case key do
        "cpu" -> ["min_cores", "cores", "min"]
        "gpu" -> ["min_count", "count", "min"]
        _ -> ["min"]
      end

    Enum.find_value(keys, fn candidate -> Values.map_get(value, candidate) end)
    |> numeric()
  end

  defp requirement_value(value, _key), do: numeric(value)

  defp parse_size_gb(value) when is_binary(value) do
    case Regex.run(~r/^\s*([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)\s*$/, value) do
      [_, number, unit] ->
        parsed = numeric(number)

        case String.downcase(unit) do
          unit when unit in ["mb", "mib"] -> parsed / 1024
          unit when unit in ["tb", "tib"] -> parsed * 1024
          _ -> parsed
        end

      _ ->
        nil
    end
  end

  defp parse_size_gb(value), do: numeric(value)

  defp memory_gb(memory) when is_map(memory) do
    cond do
      value = Values.map_get(memory, "total_mb") ->
        number_or_zero(value) / 1024

      value = Values.map_get(memory, "total_bytes") ->
        number_or_zero(value) / (1024 * 1024 * 1024)

      true ->
        0
    end
  end

  defp memory_gb(_memory), do: 0

  defp disk_available_gb(disk) when is_map(disk) do
    cond do
      value = Values.map_get(disk, "available_mb") ->
        number_or_zero(value) / 1024

      value = Values.map_get(disk, "available_bytes") ->
        number_or_zero(value) / (1024 * 1024 * 1024)

      value = Values.map_get(disk, "total_mb") ->
        number_or_zero(value) / 1024

      value = Values.map_get(disk, "total_bytes") ->
        number_or_zero(value) / (1024 * 1024 * 1024)

      true ->
        0
    end
  end

  defp disk_available_gb(_disk), do: 0

  defp node_cpu_count(node) when is_map(node) do
    node = Values.map_value(node)

    number_or_zero(
      Values.map_get(node, "cpu_cores") ||
        Values.path_get(node, "hardware.cpu.logical_processors")
    )
  end

  defp node_cpu_count(_node), do: 0

  defp node_gpu_count(node) when is_map(node) do
    node = Values.map_value(node)

    cond do
      value = Values.map_get(node, "gpu_count") -> number_or_zero(value)
      devices = Values.map_get(node, "devices") -> gpu_count(devices)
      true -> gpu_count(Values.path_get(node, "hardware.gpu"))
    end
  end

  defp node_gpu_count(_node), do: 0

  defp node_memory_gb(node) when is_map(node) do
    node = Values.map_value(node)

    case Values.map_get(node, "memory_total_gb") || Values.map_get(node, "memory_gb") do
      nil -> memory_gb(Values.path_get(node, "hardware.memory"))
      value -> number_or_zero(value)
    end
  end

  defp node_memory_gb(_node), do: 0

  defp node_disk_gb(node) when is_map(node) do
    node = Values.map_value(node)

    case Values.map_get(node, "disk_available_gb") || Values.map_get(node, "disk_gb") do
      nil -> disk_available_gb(Values.path_get(node, "hardware.disk"))
      value -> number_or_zero(value)
    end
  end

  defp node_disk_gb(_node), do: 0

  defp gpu_count(gpus) when is_list(gpus), do: length(gpus)

  defp gpu_count(gpu) when is_binary(gpu),
    do: if(String.contains?(String.downcase(gpu), "unknown"), do: 0, else: 1)

  defp gpu_count(_gpu), do: 0

  defp numeric(nil), do: nil

  defp numeric(value) when is_integer(value), do: value / 1

  defp numeric(value) when is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp numeric(_value), do: nil

  defp number_or_zero(value), do: numeric(value) || 0

  defp floor_number(value), do: value |> number_or_zero() |> Kernel.*(1.0) |> Float.floor(2)
end
