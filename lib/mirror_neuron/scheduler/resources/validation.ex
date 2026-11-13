defmodule MirrorNeuron.ResourceSpec.Validation do
  @moduledoc "Validates rich resource declarations before resource admission."

  alias MirrorNeuron.ResourceSpec.Values

  @volume_modes ["ro", "rw"]
  @volume_types ["host"]
  @port_protocols ["tcp", "udp", "http", "grpc"]

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
        validate_resource_map(Values.stringify_map(resources), node_id)
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
          validate_device(acc, device, node_id, index)
        end)

      _ ->
        ["resources.devices for node #{node_id} must be a list" | errors]
    end
  end

  defp validate_device(errors, device, node_id, index) when is_map(device) do
    path = "resources.devices[#{index}] for node #{node_id}"
    raw_count = Values.map_get(device, "count")
    count = Values.number_value(raw_count)
    raw_min_memory = Values.map_get(device, "min_memory_mb")
    min_memory = Values.number_value(raw_min_memory)
    memory_operator = Values.map_get(device, "memory_operator")
    api_version_operator = Values.map_get(device, "api_version_operator")

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
      memory_operator != nil and Values.normalize_comparison_operator(memory_operator) == nil,
      "#{path}.memory_operator must be >, >=, or =="
    )
    |> maybe_error(
      api_version_operator != nil and
        Values.normalize_comparison_operator(api_version_operator) == nil,
      "#{path}.api_version_operator must be >, >=, or =="
    )
    |> maybe_error(
      not nil_or_list?(Values.map_get(device, "ids")),
      "#{path}.ids must be a list"
    )
    |> maybe_error(
      not nil_or_list?(Values.map_get(device, "capabilities")),
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
          |> Enum.map(&(Values.map_get(&1, "label") |> to_string()))
          |> Enum.reject(&(&1 == ""))

        duplicate_labels = labels -- Enum.uniq(labels)

        ports
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {port, index}, acc ->
          validate_port(acc, port, node_id, index)
        end)
        |> add_duplicate_errors(duplicate_labels, "port label", node_id)

      _ ->
        ["resources.ports for node #{node_id} must be a list" | errors]
    end
  end

  defp validate_port(errors, port, node_id, index) when is_map(port) do
    path = "resources.ports[#{index}] for node #{node_id}"
    label = Values.map_get(port, "label")
    port_value = Values.map_get(port, "port")
    port_number = Values.number_value(port_value)
    auto_port? = Values.auto_port?(port_value)
    protocol = Values.map_get(port, "protocol") || "tcp"

    errors
    |> maybe_error(
      is_nil(label) or String.trim(to_string(label)) == "",
      "#{path}.label is required"
    )
    |> maybe_error(
      not auto_port? and (is_nil(port_number) or port_number < 1 or port_number > 65_535),
      "#{path}.port must be between 1 and 65535 or auto"
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
          |> Enum.map(&(Values.map_get(&1, "name") |> to_string()))
          |> Enum.reject(&(&1 == ""))

        duplicate_names = names -- Enum.uniq(names)

        volumes
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {volume, index}, acc ->
          validate_volume(acc, volume, node_id, index)
        end)
        |> add_duplicate_errors(duplicate_names, "volume name", node_id)

      _ ->
        ["resources.volumes for node #{node_id} must be a list" | errors]
    end
  end

  defp validate_volume(errors, volume, node_id, index) when is_map(volume) do
    path = "resources.volumes[#{index}] for node #{node_id}"
    name = Values.map_get(volume, "name")
    source = Values.map_get(volume, "source")
    target = Values.map_get(volume, "target")
    mode = Values.map_get(volume, "mode") || "ro"
    type = Values.map_get(volume, "type") || "host"

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
end
