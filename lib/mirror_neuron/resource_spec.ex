defmodule MirrorNeuron.ResourceSpec do
  @moduledoc false

  @resource_keys ["cpu_cores", "memory_mb", "disk_mb", "gpu_count"]
  @volume_modes ["ro", "rw"]
  @volume_types ["host"]
  @port_protocols ["tcp", "udp", "http", "grpc"]

  def resource_keys, do: @resource_keys

  def empty_resources, do: Map.new(@resource_keys, &{&1, 0})

  def normalize_request(resources) when is_map(resources) do
    resources = stringify_map(resources)
    devices = normalize_device_requests(Map.get(resources, "devices", []))
    ports = normalize_ports(Map.get(resources, "ports", []))
    volumes = normalize_volumes(Map.get(resources, "volumes", []))

    scalar = %{
      "cpu_cores" =>
        first_number(resources, ["cpu_cores", "cores"]) ||
          cpu_value(first_number(resources, ["cpu", "cpu_millis", "cpu_mcores"])) ||
          0.0,
      "memory_mb" =>
        first_number(resources, ["memory_mb", "memory"]) ||
          gb_to_mb(first_number(resources, ["memory_gb"])) ||
          0.0,
      "disk_mb" =>
        first_number(resources, ["disk_mb", "disk"]) ||
          gb_to_mb(first_number(resources, ["disk_gb"])) ||
          0.0,
      "gpu_count" =>
        first_number(resources, ["gpu_count", "gpus", "gpu"]) ||
          gpu_device_count(devices) ||
          0
    }

    %{
      "resources" => scalar,
      "devices" => devices,
      "ports" => ports,
      "volumes" => volumes,
      "runtime_driver" => blank_to_nil(Map.get(resources, "runtime_driver"))
    }
  end

  def normalize_request(_resources) do
    %{
      "resources" => empty_resources(),
      "devices" => [],
      "ports" => [],
      "volumes" => [],
      "runtime_driver" => nil
    }
  end

  def scalar_resources(resources) when is_map(resources) do
    normalize_request(resources)["resources"]
  end

  def scalar_resources(_resources), do: empty_resources()

  def add_gpu_need(%{"resources" => resources} = spec, count) when is_number(count) do
    next_resources = Map.update(resources, "gpu_count", count, &max(&1 || 0, count))
    Map.put(spec, "resources", next_resources)
  end

  def add_gpu_need(spec, _count), do: spec

  def with_runtime_driver(%{"runtime_driver" => nil} = spec, driver) do
    Map.put(spec, "runtime_driver", blank_to_nil(driver))
  end

  def with_runtime_driver(spec, _driver), do: spec

  def infer_runtime_driver(config) when is_map(config) do
    runner_module = map_get(config, "runner_module") |> to_string()

    cond do
      runner_module == "" ->
        nil

      String.ends_with?(runner_module, ".HostLocal") ->
        "host_local"

      String.ends_with?(runner_module, ".OpenShell") ->
        "openshell"

      String.ends_with?(runner_module, ".DockerWorker") ->
        "docker_worker"

      true ->
        nil
    end
  end

  def infer_runtime_driver(_config), do: nil

  def scheduling_devices(%{"devices" => devices, "resources" => resources}) do
    case devices do
      [] ->
        case number_value(Map.get(resources || %{}, "gpu_count")) do
          count when is_number(count) and count > 0 ->
            [%{"kind" => "gpu", "type" => "gpu", "count" => trunc(count)}]

          _ ->
            []
        end

      devices ->
        devices
    end
  end

  def scheduling_devices(_spec), do: []

  def normalize_node_devices(hardware_or_node) when is_map(hardware_or_node) do
    hardware = map_get(hardware_or_node, "hardware") || hardware_or_node

    explicit =
      map_get(hardware_or_node, "devices") ||
        map_get(hardware, "devices") ||
        []

    gpu = map_get(hardware, "gpu")

    devices =
      explicit
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {device, index} -> normalize_device_record(device, index) end)
      |> Enum.reject(&is_nil/1)

    gpu_devices =
      gpu
      |> gpu_records()
      |> Enum.with_index()
      |> Enum.map(fn {device, index} -> normalize_device_record(device, index) end)
      |> Enum.reject(&is_nil/1)

    (devices ++ gpu_devices)
    |> Enum.uniq_by(& &1["id"])
  end

  def normalize_node_devices(_hardware), do: []

  def normalize_node_host_paths(node, hardware \\ %{}) do
    node_paths =
      map_get(node, "host_paths") ||
        map_get(node, "volumes") ||
        map_get(node, "volume_paths")

    hardware_paths =
      map_get(hardware || %{}, "host_paths") ||
        map_get(hardware || %{}, "volume_paths")

    (list_value(node_paths) ++ list_value(hardware_paths))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  def normalize_node_runtime_drivers(node, hardware \\ %{}) do
    drivers =
      list_value(map_get(node, "runtime_drivers")) ++
        list_value(map_get(hardware || %{}, "runtime_drivers"))

    case drivers |> Enum.map(&String.downcase/1) |> Enum.uniq() do
      [] -> ["host_local"]
      values -> values
    end
  end

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

  def validate_manifest(manifest) do
    manifest.nodes
    |> Enum.flat_map(&validate_node/1)
  end

  def validate_node(node) do
    resources = Map.get(node, :resources) || Map.get(node, "resources") || %{}
    node_id = Map.get(node, :node_id) || Map.get(node, "node_id") || "unknown"

    cond do
      not is_map(resources) ->
        ["resources for node #{node_id} must be an object"]

      true ->
        validate_resource_map(stringify_map(resources), node_id)
    end
  end

  defp validate_resource_map(resources, node_id) do
    []
    |> validate_devices(resources, node_id)
    |> validate_ports(resources, node_id)
    |> validate_volumes(resources, node_id)
    |> validate_runtime_driver(resources, node_id)
  end

  defp validate_devices(errors, resources, node_id) do
    case Map.get(resources, "devices") do
      nil ->
        errors

      devices when is_list(devices) ->
        devices
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {device, index}, acc ->
          validate_device(acc, stringify_map(device), node_id, index)
        end)

      _ ->
        ["resources.devices for node #{node_id} must be a list" | errors]
    end
  end

  defp validate_device(errors, device, node_id, index) when is_map(device) do
    path = "resources.devices[#{index}] for node #{node_id}"
    raw_count = map_get(device, "count")
    count = number_value(raw_count)
    raw_min_memory = map_get(device, "min_memory_mb")
    min_memory = number_value(raw_min_memory)
    memory_operator = map_get(device, "memory_operator")
    api_version_operator = map_get(device, "api_version_operator")

    errors
    |> maybe_error(
      raw_count != nil and (is_nil(count) or count <= 0),
      "#{path}.count must be greater than zero"
    )
    |> maybe_error(
      raw_min_memory != nil and (is_nil(min_memory) or min_memory < 0),
      "#{path}.min_memory_mb must be zero or greater"
    )
    |> maybe_error(
      memory_operator != nil and normalize_comparison_operator(memory_operator) == nil,
      "#{path}.memory_operator must be >, >=, or =="
    )
    |> maybe_error(
      api_version_operator != nil and normalize_comparison_operator(api_version_operator) == nil,
      "#{path}.api_version_operator must be >, >=, or =="
    )
    |> maybe_error(
      not nil_or_list?(map_get(device, "ids")),
      "#{path}.ids must be a list"
    )
    |> maybe_error(
      not nil_or_list?(map_get(device, "capabilities")),
      "#{path}.capabilities must be a list"
    )
  end

  defp validate_device(errors, _device, node_id, index) do
    ["resources.devices[#{index}] for node #{node_id} must be an object" | errors]
  end

  defp validate_ports(errors, resources, node_id) do
    case Map.get(resources, "ports") do
      nil ->
        errors

      ports when is_list(ports) ->
        labels =
          ports
          |> Enum.map(&(map_get(&1, "label") |> to_string()))
          |> Enum.reject(&(&1 == ""))

        duplicate_labels = labels -- Enum.uniq(labels)

        ports
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {port, index}, acc ->
          validate_port(acc, stringify_map(port), node_id, index)
        end)
        |> add_duplicate_errors(duplicate_labels, "port label", node_id)

      _ ->
        ["resources.ports for node #{node_id} must be a list" | errors]
    end
  end

  defp validate_port(errors, port, node_id, index) when is_map(port) do
    path = "resources.ports[#{index}] for node #{node_id}"
    label = map_get(port, "label")
    port_number = number_value(map_get(port, "port"))
    protocol = map_get(port, "protocol") || "tcp"

    errors
    |> maybe_error(
      is_nil(label) or String.trim(to_string(label)) == "",
      "#{path}.label is required"
    )
    |> maybe_error(
      is_nil(port_number) or port_number < 1 or port_number > 65_535,
      "#{path}.port must be between 1 and 65535"
    )
    |> maybe_error(
      String.downcase(to_string(protocol)) not in @port_protocols,
      "#{path}.protocol must be one of #{Enum.join(@port_protocols, ", ")}"
    )
  end

  defp validate_port(errors, _port, node_id, index) do
    ["resources.ports[#{index}] for node #{node_id} must be an object" | errors]
  end

  defp validate_volumes(errors, resources, node_id) do
    case Map.get(resources, "volumes") do
      nil ->
        errors

      volumes when is_list(volumes) ->
        names =
          volumes
          |> Enum.map(&(map_get(&1, "name") |> to_string()))
          |> Enum.reject(&(&1 == ""))

        duplicate_names = names -- Enum.uniq(names)

        volumes
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {volume, index}, acc ->
          validate_volume(acc, stringify_map(volume), node_id, index)
        end)
        |> add_duplicate_errors(duplicate_names, "volume name", node_id)

      _ ->
        ["resources.volumes for node #{node_id} must be a list" | errors]
    end
  end

  defp validate_volume(errors, volume, node_id, index) when is_map(volume) do
    path = "resources.volumes[#{index}] for node #{node_id}"
    name = map_get(volume, "name")
    source = map_get(volume, "source")
    target = map_get(volume, "target")
    mode = map_get(volume, "mode") || "ro"
    type = map_get(volume, "type") || "host"

    errors
    |> maybe_error(is_nil(name) or String.trim(to_string(name)) == "", "#{path}.name is required")
    |> maybe_error(
      not absolute_path?(source),
      "#{path}.source must be an absolute host path"
    )
    |> maybe_error(
      not absolute_path?(target),
      "#{path}.target must be an absolute target path"
    )
    |> maybe_error(
      String.downcase(to_string(mode)) not in @volume_modes,
      "#{path}.mode must be ro or rw"
    )
    |> maybe_error(
      String.downcase(to_string(type)) not in @volume_types,
      "#{path}.type must be host"
    )
  end

  defp validate_volume(errors, _volume, node_id, index) do
    ["resources.volumes[#{index}] for node #{node_id} must be an object" | errors]
  end

  defp validate_runtime_driver(errors, resources, node_id) do
    case Map.get(resources, "runtime_driver") do
      nil ->
        errors

      value when is_binary(value) ->
        maybe_error(
          errors,
          String.trim(value) == "",
          "runtime_driver for node #{node_id} must not be empty"
        )

      _ ->
        ["runtime_driver for node #{node_id} must be a string" | errors]
    end
  end

  defp normalize_device_requests(devices) when is_list(devices) do
    devices
    |> Enum.with_index()
    |> Enum.map(fn {device, index} -> normalize_device_request(device, index) end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_device_requests(nil), do: []
  defp normalize_device_requests(_devices), do: []

  defp normalize_device_request(device, _index) when is_map(device) do
    device = stringify_map(device)
    type = blank_to_nil(map_get(device, "type"))
    kind = blank_to_nil(map_get(device, "kind")) || kind_from_type(type)

    %{
      "kind" => kind || "device",
      "type" => type || kind || "device",
      "count" => trunc(number_value(map_get(device, "count")) || 1),
      "vendor" => blank_to_nil(map_get(device, "vendor")),
      "driver" => blank_to_nil(map_get(device, "driver")),
      "min_memory_mb" => number_value(map_get(device, "min_memory_mb")),
      "memory_operator" => normalize_comparison_operator(map_get(device, "memory_operator")),
      "min_api_version" => trim_to_nil(map_get(device, "min_api_version")),
      "api_version_operator" =>
        normalize_comparison_operator(map_get(device, "api_version_operator")),
      "capabilities" => list_value(map_get(device, "capabilities")),
      "ids" => list_value(map_get(device, "ids"))
    }
  end

  defp normalize_device_request(_device, _index), do: nil

  defp normalize_ports(ports) when is_list(ports) do
    ports
    |> Enum.map(&normalize_port/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_ports(nil), do: []
  defp normalize_ports(_ports), do: []

  defp normalize_port(port) when is_map(port) do
    port = stringify_map(port)
    label = map_get(port, "label")
    number = number_value(map_get(port, "port"))

    if is_nil(label) or is_nil(number) do
      nil
    else
      %{
        "label" => to_string(label),
        "port" => trunc(number),
        "protocol" => String.downcase(to_string(map_get(port, "protocol") || "tcp"))
      }
    end
  end

  defp normalize_port(_port), do: nil

  defp normalize_volumes(volumes) when is_list(volumes) do
    volumes
    |> Enum.map(&normalize_volume/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_volumes(nil), do: []
  defp normalize_volumes(_volumes), do: []

  defp normalize_volume(volume) when is_map(volume) do
    volume = stringify_map(volume)
    name = map_get(volume, "name")
    source = map_get(volume, "source")
    target = map_get(volume, "target")

    if is_nil(name) or is_nil(source) or is_nil(target) do
      nil
    else
      %{
        "name" => to_string(name),
        "source" => Path.expand(to_string(source)),
        "target" => to_string(target),
        "mode" => String.downcase(to_string(map_get(volume, "mode") || "ro")),
        "type" => String.downcase(to_string(map_get(volume, "type") || "host"))
      }
    end
  end

  defp normalize_volume(_volume), do: nil

  defp normalize_device_record(device, index) when is_map(device) do
    device = stringify_map(device)

    kind =
      blank_to_nil(map_get(device, "kind")) || kind_from_type(map_get(device, "type")) || "gpu"

    vendor = blank_to_nil(map_get(device, "vendor")) || vendor_from_device(device)
    driver = blank_to_nil(map_get(device, "driver")) || driver_from_vendor(vendor)

    id =
      trim_to_nil(map_get(device, "id")) || trim_to_nil(map_get(device, "uuid")) ||
        "#{kind}-#{index}"

    total = number_value(map_get(device, "memory_total_mb") || map_get(device, "memory_mb"))
    free = number_value(map_get(device, "memory_free_mb"))
    used = number_value(map_get(device, "memory_used_mb"))

    free =
      cond do
        is_number(free) -> free
        is_number(total) and is_number(used) -> max(total - used, 0)
        true -> nil
      end

    capabilities =
      (list_value(map_get(device, "capabilities")) ++ [kind, vendor, driver])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{
      "id" => to_string(id),
      "index" => integer_value(map_get(device, "index")) || index,
      "name" => map_get(device, "name") || "#{kind}-#{index}",
      "model" => trim_to_nil(map_get(device, "model") || map_get(device, "name")),
      "kind" => kind,
      "type" => map_get(device, "type") || type_from_vendor_kind(vendor, kind),
      "vendor" => vendor,
      "driver" => driver,
      "api" => blank_to_nil(map_get(device, "api")),
      "api_version" => trim_to_nil(map_get(device, "api_version")),
      "driver_version" => trim_to_nil(map_get(device, "driver_version")),
      "gpu_type" => trim_to_nil(map_get(device, "gpu_type")),
      "memory_total_mb" => total,
      "memory_free_mb" => free,
      "memory_used_mb" => used,
      "utilization_ratio" => number_value(map_get(device, "utilization_ratio")),
      "memory_used_ratio" => number_value(map_get(device, "memory_used_ratio")),
      "capabilities" => capabilities
    }
  end

  defp normalize_device_record(device, index) when is_binary(device) do
    if unknown_gpu?(device) do
      nil
    else
      %{
        "id" => "gpu-#{index}",
        "index" => index,
        "name" => device,
        "model" => device,
        "kind" => "gpu",
        "type" => "gpu",
        "vendor" => nil,
        "driver" => nil,
        "api" => nil,
        "api_version" => nil,
        "driver_version" => nil,
        "gpu_type" => nil,
        "memory_total_mb" => nil,
        "memory_free_mb" => nil,
        "memory_used_mb" => nil,
        "utilization_ratio" => nil,
        "memory_used_ratio" => nil,
        "capabilities" => ["gpu"]
      }
    end
  end

  defp normalize_device_record(_device, _index), do: nil

  defp gpu_records(gpus) when is_list(gpus), do: gpus
  defp gpu_records(gpu) when is_map(gpu), do: [gpu]
  defp gpu_records(gpu) when is_binary(gpu), do: if(unknown_gpu?(gpu), do: [], else: [gpu])
  defp gpu_records(_gpu), do: []

  defp gpu_device_count(devices) do
    count =
      devices
      |> Enum.filter(fn device ->
        String.contains?(String.downcase(to_string(map_get(device, "kind"))), "gpu") or
          String.contains?(String.downcase(to_string(map_get(device, "type"))), "gpu")
      end)
      |> Enum.map(&(number_value(map_get(&1, "count")) || 1))
      |> Enum.sum()

    if count > 0, do: count, else: nil
  end

  defp cpu_value(nil), do: nil
  defp cpu_value(value) when value > 64, do: Float.round(value / 1000, 3)
  defp cpu_value(value), do: value

  defp gb_to_mb(nil), do: nil
  defp gb_to_mb(value), do: value * 1024

  defp first_number(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      map_get(map, key) |> number_value()
    end)
  end

  defp number_value(value) when is_integer(value), do: value
  defp number_value(value) when is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_value), do: nil

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp type_from_vendor_kind(nil, kind), do: kind
  defp type_from_vendor_kind(vendor, kind), do: "#{vendor}/#{kind}"

  defp vendor_from_device(device) do
    name = String.downcase(to_string(map_get(device, "name") || map_get(device, "type") || ""))

    cond do
      String.contains?(name, "nvidia") -> "nvidia"
      String.contains?(name, "amd") or String.contains?(name, "radeon") -> "amd"
      String.contains?(name, "apple") or String.contains?(name, "metal") -> "apple"
      true -> nil
    end
  end

  defp driver_from_vendor("nvidia"), do: "cuda"
  defp driver_from_vendor("amd"), do: "rocm"
  defp driver_from_vendor("apple"), do: "metal"
  defp driver_from_vendor(_vendor), do: nil

  defp normalize_comparison_operator(nil), do: nil

  defp normalize_comparison_operator(value) do
    case value |> to_string() |> String.trim() do
      operator when operator in [">", ">=", "=="] -> operator
      "=" -> "=="
      _other -> nil
    end
  end

  defp kind_from_type(nil), do: nil

  defp kind_from_type(type) do
    type = String.downcase(to_string(type))

    cond do
      String.contains?(type, "gpu") -> "gpu"
      String.contains?(type, "fpga") -> "fpga"
      String.contains?(type, "tpu") -> "tpu"
      true -> nil
    end
  end

  defp unknown_gpu?(gpu) do
    normalized = String.downcase(to_string(gpu))

    Enum.any?(["unknown", "none", "unsupported", "not available"], fn marker ->
      String.contains?(normalized, marker)
    end)
  end

  defp add_duplicate_errors(errors, duplicates, label, node_id) do
    duplicates
    |> Enum.uniq()
    |> Enum.reduce(errors, fn duplicate, acc ->
      ["duplicate #{label} #{inspect(duplicate)} for node #{node_id}" | acc]
    end)
  end

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors

  defp nil_or_list?(nil), do: true
  defp nil_or_list?(value), do: is_list(value)

  defp absolute_path?(value) when is_binary(value), do: Path.type(value) == :absolute
  defp absolute_path?(_value), do: false

  defp env_suffix(value) do
    value
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/, "_")
    |> String.trim("_")
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: String.downcase(value)
  end

  defp trim_to_nil(nil), do: nil

  defp trim_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end

  defp list_value(value) when is_list(value), do: Enum.map(value, &to_string/1)

  defp list_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_value(nil), do: []
  defp list_value(value), do: [to_string(value)]

  defp map_get(map, key), do: MirrorNeuron.SafeAccess.map_get(map, key)

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
