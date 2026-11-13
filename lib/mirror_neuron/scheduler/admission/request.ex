defmodule MirrorNeuron.Scheduler.Admission.Request do
  @moduledoc "Validates a run's resource budget against its workers and hardware requirements."

  alias MirrorNeuron.{HardwareRequirements, ResourceSpec}
  @scalars ~w(cpu_cores memory_mb disk_mb)

  def request(manifest) do
    policies = field(manifest, "policies") || %{}
    profile = field(policies, "resource_allocation") || %{"mode" => "exclusive_node"}

    specs =
      manifest_nodes(manifest)
      |> Enum.map(fn node -> ResourceSpec.normalize_request(field(node, "resources") || %{}) end)

    requirements = worker_requirements(manifest, specs)
    ports = Enum.flat_map(specs, & &1["ports"])
    volumes = Enum.flat_map(specs, & &1["volumes"])

    profile =
      if is_map(profile) and profile["mode"] == "exclusive_node" and
           Enum.all?(@scalars, &valid_number?(profile[&1] || 0)) do
        Enum.reduce(@scalars, profile, fn key, acc ->
          Map.put(
            acc,
            key,
            max(number(acc[key]), Enum.sum(Enum.map(specs, &(&1["resources"][key] || 0))))
          )
        end)
      else
        profile
      end

    with true <- is_map(profile),
         mode when mode in ["shared", "exclusive_node"] <- profile["mode"],
         true <- Enum.all?(@scalars, &valid_number?(profile[&1] || 0)),
         true <-
           mode != "shared" or
             (positive?(profile["cpu_cores"]) and positive?(profile["memory_mb"])),
         devices when is_list(devices) and length(devices) <= 64 <-
           Map.get(profile, "devices", []),
         true <- Enum.all?(devices, &valid_device?/1),
         true <- mode != "shared" or Enum.all?(ports, &is_integer(&1["port"])),
         true <- mode != "shared" or budget_covers_workers?(profile, specs, manifest) do
      {:ok,
       Map.merge(Map.take(profile, @scalars), %{
         "mode" => mode,
         "devices" => devices,
         "ports" => ports,
         "volumes" => volumes,
         "requirements" => requirements
       })}
    else
      _ -> {:error, :invalid_resource_allocation}
    end
  end

  defp worker_requirements(manifest, specs) do
    devices = Enum.flat_map(specs, & &1["devices"])
    gpu = HardwareRequirements.gpu_requirement(field(manifest, "requirements") || %{})

    if gpu && gpu["enforcement"] in ["hard", "required"],
      do: [Map.put(gpu, "count", trunc(gpu["min_count"] || 1)) | devices],
      else: devices
  end

  defp budget_covers_workers?(profile, specs, manifest) do
    scalars_fit =
      Enum.all?(@scalars, fn key ->
        (profile[key] || 0) >= Enum.sum(Enum.map(specs, &(&1["resources"][key] || 0)))
      end)

    gpu_count = Enum.sum(Enum.map(profile["devices"] || [], &(&1["count"] || 1)))
    node_gpu_count = Enum.max([0 | Enum.map(specs, &(&1["resources"]["gpu_count"] || 0))])

    docker_gpu =
      Enum.any?(manifest_nodes(manifest), fn node ->
        config = field(node, "config") || %{}
        value = field(field(config, "docker") || %{}, "gpus") || field(config, "gpus")
        value not in [nil, false, "", "none", 0]
      end)

    scalars_fit and gpu_count >= node_gpu_count and (not docker_gpu or gpu_count > 0)
  end

  defp manifest_nodes(manifest) do
    List.wrap(
      field(manifest, "nodes") || field(field(manifest, "flow") || %{}, "nodes") ||
        field(field(manifest, "agents") || %{}, "nodes")
    )
  end

  defp valid_device?(device) when is_map(device) do
    models = device["models"] || []

    device["sharing"] in [nil, "exclusive", "shared"] and
      valid_number?(device["reservation_memory_mb"] || 0) and
      valid_number?(device["min_memory_mb"] || 0) and
      Enum.all?(~w(vendor driver min_api_version), fn key ->
        is_nil(device[key]) or (is_binary(device[key]) and byte_size(device[key]) in 1..80)
      end) and
      Enum.all?(~w(ids models_allowed capabilities), fn key ->
        is_nil(device[key]) or (is_list(device[key]) and Enum.all?(device[key], &is_binary/1))
      end) and
      is_integer(device["count"] || 1) and (device["count"] || 1) in 1..64 and
      (device["sharing"] != "shared" or positive?(device["reservation_memory_mb"])) and
      is_list(models) and length(models) <= 64 and
      Enum.all?(models, fn model ->
        is_map(model) and is_binary(model["key"]) and byte_size(model["key"]) in 1..200 and
          positive?(model["memory_mb"])
      end) and
      (models == [] or
         (Enum.sum(Enum.map(models, & &1["memory_mb"])) <= (device["reservation_memory_mb"] || 0) and
            length(Enum.uniq_by(models, & &1["key"])) == length(models)))
  end

  defp valid_device?(_), do: false
  defp valid_number?(value), do: is_number(value) and value >= 0 and value <= 1.0e12
  defp positive?(value), do: valid_number?(value) and value > 0
  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_), do: 0
  defp field(map, key), do: MirrorNeuron.SafeAccess.map_get(map, key)
end
