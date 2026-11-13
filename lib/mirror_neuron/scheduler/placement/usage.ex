defmodule MirrorNeuron.Scheduler.Placement.Usage do
  @moduledoc "Accounts for active placements, device reservations and port reservations."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ResourceSpec

  @active_job_statuses ["pending", "validated", "scheduled", "running", "paused"]
  @resource_keys ResourceSpec.resource_keys()

  defp normalize_resources(resources), do: ResourceSpec.scalar_resources(resources)

  def empty_resources, do: ResourceSpec.empty_resources()

  def active_jobs do
    # Monitoring summaries deliberately omit placements and allocations.
    # Admission must read the durable reservations before allocating resources.
    case RedisStore.list_jobs() do
      {:ok, jobs} -> jobs
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  end

  def usage_from_jobs(jobs, ignored_job_ids) do
    ignored_job_ids =
      ignored_job_ids
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    jobs
    |> List.wrap()
    |> Enum.filter(fn job ->
      Map.get(job, "status") in @active_job_statuses and
        Map.get(job, "job_id") not in ignored_job_ids
    end)
    |> Enum.flat_map(&(get_in(&1, ["scheduler", "placements"]) || []))
    |> Enum.reduce(%{}, fn placement, acc ->
      node = Map.get(placement, "node")
      resources = normalize_resources(Map.get(placement, "resources", %{}))
      allocation = Map.get(placement, "allocations", %{})

      if is_binary(node) do
        Map.update(
          acc,
          node,
          add_usage(empty_usage(), resources, allocation),
          &add_usage(&1, resources, allocation)
        )
      else
        acc
      end
    end)
  end

  def empty_usage do
    %{
      "resources" => empty_resources(),
      "devices" => MapSet.new(),
      "ports" => MapSet.new()
    }
  end

  def normalize_usage(%{"resources" => resources} = usage) do
    %{
      "share_devices" => Map.get(usage, "share_devices", false),
      "resources" => normalize_resources(resources),
      "devices" => Map.get(usage, "devices", MapSet.new()) |> to_mapset(),
      "ports" => Map.get(usage, "ports", MapSet.new()) |> to_mapset()
    }
  end

  def normalize_usage(usage) when is_map(usage) do
    %{
      "resources" => normalize_resources(usage),
      "devices" => MapSet.new(),
      "ports" => MapSet.new()
    }
  end

  def normalize_usage(_usage), do: empty_usage()

  def usage_for_node(usage, node_name),
    do: Map.get(usage, node_name, empty_usage()) |> normalize_usage()

  def add_usage(used, resources, allocation) do
    used = normalize_usage(used)
    combined = add_resources(used["resources"], resources)

    combined =
      if used["share_devices"],
        do:
          Map.put(
            combined,
            "gpu_count",
            max(used["resources"]["gpu_count"] || 0, resources["gpu_count"] || 0)
          ),
        else: combined

    %{
      "share_devices" => used["share_devices"],
      "resources" => combined,
      "devices" => MapSet.union(used["devices"], allocated_device_ids(allocation)),
      "ports" => MapSet.union(used["ports"], allocated_port_keys(allocation))
    }
  end

  def merge_usage(left, right) do
    left = normalize_usage(left)
    right = normalize_usage(right)

    shared = left["share_devices"] || right["share_devices"]
    resources = add_resources(left["resources"], right["resources"])

    resources =
      if shared,
        do:
          Map.put(
            resources,
            "gpu_count",
            max(left["resources"]["gpu_count"] || 0, right["resources"]["gpu_count"] || 0)
          ),
        else: resources

    %{
      "share_devices" => shared,
      "resources" => resources,
      "devices" => MapSet.union(left["devices"], right["devices"]),
      "ports" => MapSet.union(left["ports"], right["ports"])
    }
  end

  defp to_mapset(%MapSet{} = set), do: set

  defp to_mapset(values) when is_list(values), do: MapSet.new(values)

  defp to_mapset(_values), do: MapSet.new()

  def allocated_device_ids(%{"devices" => devices}) when is_list(devices) do
    devices
    |> Enum.map(&(Map.get(&1, "id") || Map.get(&1, :id)))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  def allocated_device_ids(_allocation), do: MapSet.new()

  defp allocated_port_keys(%{"ports" => ports}) when is_list(ports) do
    ports
    |> Enum.map(&port_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp allocated_port_keys(_allocation), do: MapSet.new()

  def port_key(%{"port" => port} = request) do
    protocol =
      request
      |> Map.get("protocol", "tcp")
      |> to_string()
      |> String.downcase()
      |> then(fn
        protocol when protocol in ["http", "grpc"] -> "tcp"
        protocol -> protocol
      end)

    "#{protocol}:#{trunc(port)}"
  rescue
    _ -> nil
  end

  def port_key(_request), do: nil

  def add_resources(left, right) do
    Map.new(@resource_keys, fn key ->
      {key, (Map.get(left, key, 0) || 0) + (Map.get(right, key, 0) || 0)}
    end)
  end
end
