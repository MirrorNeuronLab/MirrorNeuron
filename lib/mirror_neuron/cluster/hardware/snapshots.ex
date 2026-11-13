defmodule MirrorNeuron.Cluster.Hardware.Snapshots do
  @moduledoc "Owns cached telemetry freshness and withdraws stale admission capacity."

  alias MirrorNeuron.Cluster.Hardware.Advertisement

  def update_snapshot(hardware) when is_map(hardware) do
    :persistent_term.put(
      {MirrorNeuron.Cluster.Hardware, :snapshot},
      {System.monotonic_time(:second), atomize_hardware(hardware)}
    )

    :ok
  end

  def clear_snapshot, do: :persistent_term.erase({MirrorNeuron.Cluster.Hardware, :snapshot})

  def info do
    snapshot_info()
    |> Map.update(
      :capabilities,
      ["resource_admission_v2"],
      &Enum.uniq([
        "resource_admission_v2" | Enum.filter(List.wrap(&1), fn value -> is_binary(value) end)
      ])
    )
  end

  defp snapshot_info do
    case :persistent_term.get({MirrorNeuron.Cluster.Hardware, :snapshot}, nil) do
      {reported, hardware} ->
        if System.monotonic_time(:second) - reported <= 90,
          do: Map.put(hardware, :admission_telemetry_current, true),
          else: Map.put(unavailable_memory(hardware), :admission_telemetry_current, false)

      nil ->
        Map.put(initial_info(), :admission_telemetry_current, false)
    end
  end

  defp unavailable_memory(hardware) do
    memory =
      case Map.get(hardware, :memory) do
        value when is_map(value) -> value
        _ -> %{}
      end

    hardware
    |> Map.put(:memory, Map.merge(memory, %{available_mb: 0, available_bytes: 0}))
    |> Map.update(:gpu, [], &unavailable_devices/1)
    |> Map.update(:devices, [], &unavailable_devices/1)
  end

  defp unavailable_devices(devices) when is_list(devices) do
    devices |> Enum.filter(&is_map/1) |> Enum.map(&Map.put(&1, :memory_free_mb, 0))
  end

  defp unavailable_devices(_devices), do: []

  defp initial_info do
    case advertised_info() do
      {:ok, hardware} -> hardware
      :error -> Advertisement.runtime_advertisement_info()
    end
  end

  defp advertised_info do
    case System.get_env("MN_NODE_HARDWARE_JSON") do
      value when is_binary(value) and value != "" ->
        with {:ok, decoded} <- Jason.decode(value),
             true <- is_map(decoded) do
          {:ok, atomize_hardware(decoded)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp atomize_hardware(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      atom_key =
        if is_binary(key) do
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> key
          end
        else
          key
        end

      {atom_key, atomize_hardware(nested)}
    end)
  end

  defp atomize_hardware(value) when is_list(value), do: Enum.map(value, &atomize_hardware/1)

  defp atomize_hardware(value), do: value
end
