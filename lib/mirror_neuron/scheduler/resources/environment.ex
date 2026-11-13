defmodule MirrorNeuron.ResourceSpec.Environment do
  @moduledoc "Projects a confirmed resource allocation into runner environment variables."

  def allocation_env(allocation) when is_map(allocation) do
    devices = Map.get(allocation, "devices", [])
    ports = Map.get(allocation, "ports", [])
    volumes = Map.get(allocation, "volumes", [])

    device_ids =
      devices
      |> Enum.map(&(Map.get(&1, "id") || Map.get(&1, :id)))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    drivers =
      devices
      |> Enum.map(&(Map.get(&1, "driver") || Map.get(&1, :driver)))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    cuda_visible =
      devices
      |> Enum.filter(fn device ->
        String.downcase(to_string(Map.get(device, "driver") || Map.get(device, :driver))) ==
          "cuda"
      end)
      |> Enum.map(fn device ->
        Map.get(device, "index") || Map.get(device, :index) || Map.get(device, "id") ||
          Map.get(device, :id)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    base =
      %{}
      |> put_if(device_ids != [], "MN_ALLOCATED_DEVICE_IDS", Enum.join(device_ids, ","))
      |> put_if(drivers != [], "MN_GPU_DRIVER", Enum.join(drivers, ","))
      |> put_if(cuda_visible != [], "CUDA_VISIBLE_DEVICES", Enum.join(cuda_visible, ","))

    port_env =
      Map.new(ports, fn port ->
        {"MN_PORT_#{env_suffix(Map.get(port, "label"))}", to_string(Map.get(port, "port"))}
      end)

    volume_env =
      volumes
      |> Enum.flat_map(fn volume ->
        suffix = env_suffix(Map.get(volume, "name"))

        [
          {"MN_VOLUME_#{suffix}", to_string(Map.get(volume, "source"))},
          {"MN_VOLUME_#{suffix}_TARGET", to_string(Map.get(volume, "target"))}
        ]
      end)
      |> Map.new()

    allocation_json =
      case Jason.encode(allocation) do
        {:ok, encoded} -> %{"MN_ALLOCATION_JSON" => encoded}
        _ -> %{}
      end

    base
    |> Map.merge(port_env)
    |> Map.merge(volume_env)
    |> Map.merge(allocation_json)
  end

  def allocation_env(_allocation), do: %{}

  defp env_suffix(value) do
    value
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/, "_")
    |> String.trim("_")
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)

  defp put_if(map, false, _key, _value), do: map
end
