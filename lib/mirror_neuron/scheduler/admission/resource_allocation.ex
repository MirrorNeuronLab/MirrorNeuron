defmodule MirrorNeuron.Runtime.ResourceAllocation do
  @moduledoc "Pure admission accounting for one physical computer."

  alias MirrorNeuron.{HardwareRequirements, ResourceSpec}

  @scalars ~w(cpu_cores memory_mb disk_mb)

  defdelegate request(manifest), to: MirrorNeuron.Scheduler.Admission.Request

  def capacity(hardware, limits \\ %{}) do
    cpu = field(hardware, "cpu") || %{}
    memory = field(hardware, "memory") || %{}
    disk = field(hardware, "disk") || %{}

    %{
      "resources" => %{
        "cpu_cores" => number(field(cpu, "logical_processors")) * ratio(limits, "cpu"),
        "memory_mb" => number(field(memory, "total_mb")) * ratio(limits, "memory"),
        "disk_mb" => number(field(disk, "total_mb")) * ratio(limits, "disk")
      },
      "available" => %{
        "memory_mb" => field(memory, "available_mb"),
        "disk_mb" => field(disk, "available_mb")
      },
      "devices" => ResourceSpec.normalize_node_devices(hardware),
      "gpu_ratio" => ratio(limits, "gpu"),
      "managed_usage" => field(hardware, "managed_resource_usage") || %{},
      "shared_model_keys" => field(hardware, "shared_model_keys") || %{},
      "telemetry_current" => field(hardware, "admission_telemetry_current") != false
    }
  end

  def check(request, capacity, reservations, opts \\ []) do
    case allocate(request, capacity, reservations, opts) do
      {:ok, allocation} ->
        %{"status" => "runnable_now", "allocation" => allocation, "blockers" => []}

      {:error, blockers} ->
        empty = %{
          capacity
          | "available" => capacity["resources"],
            "devices" =>
              Enum.map(capacity["devices"], &Map.put(&1, "memory_free_mb", &1["memory_total_mb"]))
        }

        status =
          cond do
            Enum.any?(blockers, &(&1["code"] == "MN_SCHEDULING_UNAVAILABLE")) -> "unavailable"
            match?({:ok, _}, allocate(request, empty, [], opts)) -> "runnable_later"
            true -> "not_runnable"
          end

        %{"status" => status, "blockers" => blockers}
    end
  end

  def allocate(request, capacity, reservations, opts \\ []) do
    live? = Keyword.get(opts, :live, true)

    cond do
      live? and capacity["telemetry_current"] == false ->
        {:error, [blocker("MN_SCHEDULING_UNAVAILABLE", "telemetry")]}

      not requirements_fit?(request["requirements"] || [], capacity["devices"]) ->
        {:error, [blocker("MN_GPU_REQUIREMENT_UNMET", "gpu_type")]}

      Enum.any?(reservations, &(&1["mode"] == "exclusive_node")) ->
        {:error, [blocker("MN_RESOURCE_EXHAUSTED", "exclusive_node")]}

      request["mode"] == "exclusive_node" and reservations != [] ->
        {:error, [blocker("MN_RESOURCE_EXHAUSTED", "exclusive_node")]}

      request["mode"] == "exclusive_node" ->
        with :ok <- fit_scalars(request, capacity, [], live?),
             :ok <- fit_exclusive_device_floor(request, capacity, live?) do
          {:ok,
           %{
             "mode" => "exclusive_node",
             "resources" => capacity["resources"],
             "devices" => capacity["devices"]
           }}
        end

      true ->
        with :ok <- fit_exclusive_resources(request, reservations),
             :ok <- fit_scalars(request, capacity, reservations, live?),
             {:ok, devices} <- fit_devices(request["devices"], capacity, reservations, live?),
             true <- requirements_fit?(request["requirements"] || [], devices),
             :ok <- fit_unified_memory(request, devices, capacity, reservations, live?) do
          {:ok,
           %{
             "mode" => "shared",
             "resources" => Map.new(@scalars, &{&1, request[&1] || 0}),
             "devices" => devices,
             "ports" => request["ports"] || [],
             "volumes" => request["volumes"] || []
           }}
        else
          false -> {:error, [blocker("MN_GPU_REQUIREMENT_UNMET", "gpu_type")]}
          error -> error
        end
    end
  end

  defp fit_exclusive_device_floor(request, capacity, live?) do
    Enum.reduce_while(request["requirements"] || [], :ok, fn needed, :ok ->
      case fit_devices([needed], capacity, [], live?) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp fit_exclusive_resources(request, reservations) do
    port_key = fn port ->
      protocol = if port["protocol"] in [nil, "http", "grpc"], do: "tcp", else: port["protocol"]
      {protocol, port["port"]}
    end

    held_ports = reservations |> Enum.flat_map(&(&1["ports"] || [])) |> MapSet.new(port_key)
    port_conflict = Enum.any?(request["ports"] || [], &MapSet.member?(held_ports, port_key.(&1)))
    held_volumes = Enum.flat_map(reservations, &(&1["volumes"] || []))

    volume_conflict =
      Enum.any?(request["volumes"] || [], fn volume ->
        Enum.any?(held_volumes, fn held ->
          source = Path.expand(volume["source"])
          other = Path.expand(held["source"])

          overlap =
            source == other or String.starts_with?(source, other <> "/") or
              String.starts_with?(other, source <> "/")

          overlap and (volume["mode"] == "rw" or held["mode"] == "rw")
        end)
      end)

    cond do
      port_conflict -> {:error, [blocker("MN_RESOURCE_EXHAUSTED", "port")]}
      volume_conflict -> {:error, [blocker("MN_RESOURCE_EXHAUSTED", "writable_volume")]}
      true -> :ok
    end
  end

  defp fit_scalars(request, capacity, reservations, live?) do
    blockers =
      Enum.flat_map(@scalars, fn key ->
        required = request[key] || 0
        reserved = Enum.sum(Enum.map(reservations, &(get_in(&1, ["resources", key]) || 0)))
        budget = max(capacity["resources"][key] - reserved, 0)
        pending = max(reserved - managed_usage(capacity, key), 0)
        reported = capacity["available"][key]

        available =
          if live? and key != "cpu_cores" and required > 0,
            do: if(is_number(reported), do: min(budget, max(reported - pending, 0)), else: nil),
            else: budget

        cond do
          is_nil(available) -> [blocker("MN_SCHEDULING_UNAVAILABLE", key)]
          required > available -> [measurement(key, available, required)]
          true -> []
        end
      end)

    if blockers == [], do: :ok, else: {:error, blockers}
  end

  defp fit_devices(requests, capacity, reservations, live?) do
    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, allocated} ->
      candidates =
        capacity["devices"]
        |> Enum.filter(&eligible?(&1, request))
        |> Enum.sort_by(&{&1["memory_total_mb"] || 0, &1["id"]})

      count = request["count"] || 1

      picked =
        candidates
        |> Enum.reject(fn device -> Enum.any?(allocated, &(&1["id"] == device["id"])) end)
        |> Enum.flat_map(fn device ->
          held =
            Enum.flat_map(reservations, &(&1["devices"] || []))
            |> Enum.filter(&(&1["id"] == device["id"]))

          case device_allocation(device, request, held, capacity, live?) do
            {:ok, allocation} -> [allocation]
            _ -> []
          end
        end)
        |> Enum.take(count)

      if length(picked) == count do
        {:cont, {:ok, allocated ++ picked}}
      else
        reason =
          if candidates == [],
            do: blocker("MN_GPU_REQUIREMENT_UNMET", "gpu_type"),
            else: device_blocker(candidates, request, reservations, capacity, live?)

        {:halt, {:error, [reason]}}
      end
    end)
  end

  defp device_allocation(device, request, held, capacity, live?) do
    shared? = request["sharing"] == "shared"
    conflict? = held != [] and (not shared? or Enum.any?(held, &(&1["sharing"] != "shared")))
    required = if shared?, do: request["reservation_memory_mb"], else: device["memory_total_mb"]
    available = device_available(device, held, capacity, live?, shared?)

    incremental =
      incremental_memory(required, request["models"] || [], held, verified_keys(capacity, device))

    needed_now =
      if shared?,
        do: incremental,
        else: request["reservation_memory_mb"] || request["min_memory_mb"] || 0

    if not conflict? and is_number(available) and needed_now <= available do
      {:ok,
       Map.merge(device, %{
         "sharing" => request["sharing"] || "exclusive",
         "reservation_memory_mb" => required,
         "models" => request["models"] || [],
         "incremental_memory_mb" => incremental
       })}
    else
      {:error, :device_capacity_unavailable}
    end
  end

  defp device_available(device, held, capacity, live?, shared?) do
    total = device["memory_total_mb"]
    free = device["memory_free_mb"]

    if is_number(total) and (not live? or is_number(free)) do
      headroom = if shared?, do: max(512, total * 0.1), else: 0
      reserved = reserved_device_memory(held, verified_keys(capacity, device))
      budget = max(total * capacity["gpu_ratio"] - headroom - reserved, 0)
      pending = max(reserved - managed_usage(capacity, device["id"]), 0)
      if live?, do: min(budget, max(free - headroom - pending, 0)), else: budget
    end
  end

  defp device_blocker(devices, request, reservations, capacity, live?) do
    values =
      Enum.map(devices, fn device ->
        held =
          Enum.flat_map(reservations, &(&1["devices"] || []))
          |> Enum.filter(&(&1["id"] == device["id"]))

        device_available(device, held, capacity, live?, request["sharing"] == "shared")
      end)

    if Enum.any?(values, &is_number/1),
      do:
        measurement(
          "gpu_memory_free_mb",
          Enum.max(Enum.filter(values, &is_number/1)),
          request["reservation_memory_mb"] || Enum.min(Enum.map(devices, & &1["memory_total_mb"]))
        ),
      else: blocker("MN_SCHEDULING_UNAVAILABLE", "gpu_memory_free_mb")
  end

  defp fit_unified_memory(request, devices, capacity, reservations, live?) do
    additional =
      Enum.sum(for device <- devices, unified?(device), do: device["incremental_memory_mb"])

    reserved = reserved_unified_memory(reservations, capacity)

    if additional + reserved > 0 do
      # Unified GPU slices already held by other Jobs use host RAM even when
      # the incoming request is CPU-only. Keep those bytes on the held side
      # of the live-telemetry calculation.
      fit_scalars(
        Map.put(request, "memory_mb", (request["memory_mb"] || 0) + additional),
        capacity,
        [%{"resources" => %{"memory_mb" => reserved}} | reservations],
        live?
      )
    else
      :ok
    end
  end

  defp unified?(device),
    do: Enum.any?(device["capabilities"] || [], &(&1 in ["unified-memory", "unified_memory"]))

  defp reserved_unified_memory(reservations, capacity) do
    reservations
    |> Enum.flat_map(&(&1["devices"] || []))
    |> Enum.filter(&unified?/1)
    |> Enum.group_by(& &1["id"])
    |> Enum.reduce(0, fn {_id, [device | _] = claims}, total ->
      total + reserved_device_memory(claims, verified_keys(capacity, device))
    end)
  end

  defp requirements_fit?(requirements, devices) do
    Enum.all?(requirements, fn requirement ->
      Enum.count(devices, &eligible?(&1, requirement)) >= (requirement["count"] || 1)
    end)
  end

  defp eligible?(device, request) do
    HardwareRequirements.device_satisfies_gpu?(
      Map.put(device, "memory_free_mb", device["memory_total_mb"]),
      %{
        "vendor" => request["vendor"],
        "driver" => request["driver"],
        "min_memory_mb" => request["min_memory_mb"],
        "memory_operator" => request["memory_operator"] || ">=",
        "min_api_version" => request["min_api_version"],
        "api_version_operator" => request["api_version_operator"] || ">=",
        "required_capabilities" => []
      }
    ) and (request["ids"] in [nil, []] or device["id"] in request["ids"]) and
      (request["models_allowed"] in [nil, []] or device["model"] in request["models_allowed"]) and
      Enum.all?(
        request["capabilities"] || request["required_capabilities"] || [],
        &(&1 in (device["capabilities"] || []))
      )
  end

  defp reserved_device_memory(devices, verified) do
    devices =
      Enum.map(
        devices,
        &Map.update(&1, "models", [], fn models ->
          Enum.filter(models, fn model -> model["key"] in verified end)
        end)
      )

    private =
      Enum.sum(
        Enum.map(devices, fn device ->
          (device["reservation_memory_mb"] || device["memory_total_mb"] || 0) -
            Enum.sum(Enum.map(device["models"] || [], & &1["memory_mb"]))
        end)
      )

    models = devices |> Enum.flat_map(&(&1["models"] || [])) |> Enum.uniq_by(&weight_identity/1)
    private + Enum.sum(Enum.map(models, & &1["memory_mb"]))
  end

  defp incremental_memory(required, models, held, verified) do
    models = Enum.filter(models, &(&1["key"] in verified))

    resident = held |> Enum.flat_map(&(&1["models"] || [])) |> MapSet.new(&weight_identity/1)

    required -
      Enum.sum(
        for model <- models,
            MapSet.member?(resident, weight_identity(model)),
            do: model["memory_mb"]
      )
  end

  # Both ledgers use the same sharing rule. JSON integers and floats can
  # describe the same size, but different estimates get no shared discount.
  defp weight_identity(model), do: {model["key"], model["memory_mb"] * 1.0}

  defp verified_keys(capacity, device),
    do: (capacity["shared_model_keys"] || %{})[device["id"]] || []

  defp managed_usage(capacity, key), do: number(field(capacity["managed_usage"], key))

  defp measurement(key, available, required) do
    {unit, scale, code} =
      case key do
        "cpu_cores" -> {"cores", 1, "MN_RESOURCE_EXHAUSTED"}
        "gpu_memory_free_mb" -> {"GiB", 1024, "MN_GPU_MEMORY_UNAVAILABLE"}
        "disk_mb" -> {"GiB", 1024, "MN_DISK_UNAVAILABLE"}
        _ -> {"GiB", 1024, "MN_RESOURCE_EXHAUSTED"}
      end

    Map.merge(blocker(code, key), %{
      "available" => available / scale,
      "required" => required / scale,
      "unit" => unit,
      "operator" => ">="
    })
  end

  defp blocker(code, resource), do: %{"code" => code, "resource" => resource, "node_index" => 1}
  defp ratio(limits, key), do: (limits[key] || 100) / 100
  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_), do: 0
  defp field(map, key), do: MirrorNeuron.SafeAccess.map_get(map, key)
end
