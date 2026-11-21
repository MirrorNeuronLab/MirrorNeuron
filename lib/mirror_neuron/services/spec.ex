defmodule MirrorNeuron.ServiceSpec do
  @moduledoc false

  alias MirrorNeuron.ResourceSpec

  @check_types ["http", "tcp", "script", "grpc"]
  @origins ["internal", "external"]
  @providers ["mirror_neuron"]
  @name_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
  @unsafe_command_pattern ~r/[;&|`<>]|\$\(|\n|\r/

  def normalize_services(nil), do: []
  def normalize_services(value) when is_list(value), do: Enum.map(value, &normalize_service/1)
  def normalize_services(value) when is_map(value), do: [normalize_service(value)]
  def normalize_services(value), do: value

  def normalize_required_services(nil), do: []

  def normalize_required_services(value) when is_list(value),
    do: Enum.map(value, &normalize_required_service/1)

  def normalize_required_services(value) when is_map(value),
    do: [normalize_required_service(value)]

  def normalize_required_services(value), do: value

  def normalize_requires_services(value) when is_list(value),
    do: normalize_required_services(value)

  def normalize_requires_services(value) when is_map(value),
    do: normalize_required_services([value])

  def normalize_requires_services(nil), do: []
  def normalize_requires_services(_value), do: []

  def validate_manifest(manifest) do
    []
    |> validate_service_list("services", Map.get(manifest, :services, []), :service)
    |> validate_service_list(
      "required_services",
      Map.get(manifest, :required_services, []),
      :required_service
    )
    |> validate_node_service_lists(manifest)
    |> Enum.reverse()
  end

  def service_instances_for_job(manifest, job_id, opts \\ []) do
    context = base_context(manifest, job_id, opts)

    manifest
    |> Map.get(:services, [])
    |> Enum.map(&resolve_service(&1, context))
  end

  def service_instances_for_agent(manifest, job_id, node, target_node, opts \\ []) do
    source_agent_id = source_node_id(node)

    node_environment =
      node
      |> Map.get(:config, %{})
      |> map_get("environment")
      |> stringify_map()

    allocation_environment =
      opts
      |> Keyword.get(:allocation, %{})
      |> ResourceSpec.allocation_env()

    environment =
      opts
      |> Keyword.get(:env, node_environment)
      |> stringify_map()
      |> Map.merge(allocation_environment)

    opts = Keyword.put(opts, :env, environment)

    context =
      manifest
      |> base_context(job_id, opts)
      |> Map.merge(%{
        "agent_id" => Map.get(node, :node_id),
        "source_agent_id" => source_agent_id,
        "node" => target_node || to_string(Node.self())
      })

    node
    |> Map.get(:services, [])
    |> Enum.map(&resolve_service(&1, context))
  end

  def required_services(manifest), do: Map.get(manifest, :required_services, [])

  def node_requires_services(node), do: Map.get(node, :requires_services, [])

  def required?(service), do: map_get(service, "required") != false

  def resolve_service(service, context \\ %{}) when is_map(service) do
    service = stringify_map(service)
    context = stringify_map(context)

    base =
      service
      |> Map.put_new("provider", "mirror_neuron")
      |> Map.put_new("origin", "internal")
      |> Map.update("tags", [], &list_strings/1)
      |> Map.update("meta", %{}, &stringify_map/1)
      |> Map.update("checks", [], &normalize_checks/1)

    service_context =
      context
      |> Map.put("service", base)
      |> Map.put("service_name", Map.get(base, "name"))

    resolved =
      base
      |> resolve_templates(service_context)
      |> coerce_resolved_port()

    check_context = Map.put(service_context, "service", resolved)

    resolved
    |> Map.put(
      "checks",
      Enum.map(Map.get(resolved, "checks", []), &resolve_templates(&1, check_context))
    )
    |> Map.put_new("id", default_service_id(resolved, context))
    |> Map.put_new("status", initial_status(resolved))
    |> Map.put_new("health", %{"status" => initial_status(resolved), "checks" => []})
    |> maybe_put("job_id", Map.get(context, "job_id"))
    |> maybe_put("agent_id", Map.get(context, "agent_id"))
    |> maybe_put("source_agent_id", Map.get(context, "source_agent_id"))
    |> maybe_put("node", Map.get(context, "node"))
    |> maybe_put("bundle_root", Map.get(context, "bundle_root"))
    |> Map.put("updated_at", timestamp())
  end

  def resolve_templates(value, context) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {key, resolve_templates(item, context)}
    end)
  end

  def resolve_templates(value, context) when is_list(value),
    do: Enum.map(value, &resolve_templates(&1, context))

  def resolve_templates(value, context) when is_binary(value) do
    Regex.replace(~r/\$\{([^}]+)\}/, value, fn _match, path ->
      context
      |> path_get(String.split(path, "."))
      |> template_value()
    end)
  end

  def resolve_templates(value, _context), do: value

  def service_names(requirements) do
    requirements
    |> List.wrap()
    |> Enum.map(&map_get(&1, "name"))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  def match_requirement?(service, requirement) do
    service = stringify_map(service)
    requirement = stringify_map(requirement)

    Map.get(service, "name") == Map.get(requirement, "name") and
      tags_match?(Map.get(service, "tags", []), Map.get(requirement, "tags", [])) and
      map_get(requirement, "origin") in [nil, Map.get(service, "origin")]
  end

  def map_get(map, key) when is_map(map) do
    string_key = to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> existing_atom_value(map, key)
    end
  end

  def map_get(_map, _key), do: nil

  defp existing_atom_value(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_value(_map, _key), do: nil

  def normalize_checks(value) when is_list(value),
    do: Enum.map(value, &normalize_check/1)

  def normalize_checks(value) when is_map(value), do: [normalize_check(value)]
  def normalize_checks(nil), do: []
  def normalize_checks(value), do: value

  defp normalize_service(value) when is_map(value) do
    value
    |> stringify_map()
    |> Map.put_new("provider", "mirror_neuron")
    |> Map.put_new("origin", "internal")
    |> Map.update("tags", [], &list_strings/1)
    |> Map.update("meta", %{}, &stringify_map/1)
    |> Map.update("checks", [], &normalize_checks/1)
  end

  defp normalize_service(value) when is_binary(value), do: normalize_service(%{"name" => value})
  defp normalize_service(_value), do: %{}

  defp normalize_required_service(value) when is_map(value) do
    raw = stringify_map(value)

    raw
    |> normalize_service()
    |> maybe_delete_default_requirement_origin(raw)
    |> Map.put_new("required", true)
  end

  defp normalize_required_service(value) when is_binary(value),
    do: normalize_required_service(%{"name" => value})

  defp normalize_required_service(_value), do: %{"required" => true}

  defp maybe_delete_default_requirement_origin(service, raw) do
    if Map.has_key?(raw, "origin") do
      service
    else
      Map.delete(service, "origin")
    end
  end

  defp normalize_check(value) when is_map(value) do
    value
    |> stringify_map()
    |> Map.update("type", "tcp", &(to_string(&1) |> String.downcase()))
    |> Map.put_new("name", map_get(value, "type") || "check")
    |> Map.put_new("timeout_ms", 2_000)
    |> Map.put_new("interval_ms", 10_000)
    |> Map.put_new("required", true)
    |> Map.put_new("failures_before_critical", 1)
  end

  defp normalize_check(_value),
    do: %{"type" => "tcp", "timeout_ms" => 2_000, "interval_ms" => 10_000}

  defp validate_node_service_lists(errors, manifest) do
    manifest
    |> Map.get(:nodes, [])
    |> Enum.reduce(errors, fn node, acc ->
      node_id = Map.get(node, :node_id, "unknown")

      acc
      |> validate_service_list(
        "nodes.#{node_id}.services",
        Map.get(node, :services, []),
        :service
      )
      |> validate_service_list(
        "nodes.#{node_id}.requires_services",
        Map.get(node, :requires_services, []),
        :required_service
      )
    end)
  end

  defp validate_service_list(errors, path, services, kind) when is_list(services) do
    services
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {service, index}, acc ->
      validate_service(acc, "#{path}.#{index}", service, kind)
    end)
  end

  defp validate_service_list(errors, path, _services, _kind),
    do: ["#{path} must be a list" | errors]

  defp validate_service(errors, path, service, kind) when is_map(service) do
    checks = map_get(service, "checks") || []

    errors
    |> maybe_error(invalid_name?(map_get(service, "name")), "#{path}.name must be a service name")
    |> maybe_error(
      not is_nil(map_get(service, "provider")) and map_get(service, "provider") not in @providers,
      "#{path}.provider must be mirror_neuron"
    )
    |> maybe_error(
      not is_nil(map_get(service, "origin")) and map_get(service, "origin") not in @origins,
      "#{path}.origin must be internal or external"
    )
    |> maybe_error(
      invalid_port?(map_get(service, "port")),
      "#{path}.port must be 1..65535 or a template"
    )
    |> maybe_error(not is_list(map_get(service, "tags") || []), "#{path}.tags must be a list")
    |> maybe_error(not is_map(map_get(service, "meta") || %{}), "#{path}.meta must be an object")
    |> maybe_error(not is_list(checks), "#{path}.checks must be a list")
    |> maybe_error(
      kind == :required_service and map_get(service, "required") not in [nil, true, false],
      "#{path}.required must be a boolean"
    )
    |> validate_checks(path, checks)
  end

  defp validate_service(errors, path, _service, _kind),
    do: ["#{path} must be an object" | errors]

  defp validate_checks(errors, _path, checks) when not is_list(checks), do: errors

  defp validate_checks(errors, path, checks) do
    checks
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {check, index}, acc ->
      validate_check(acc, "#{path}.checks.#{index}", check)
    end)
  end

  defp validate_check(errors, path, check) when is_map(check) do
    type = map_get(check, "type")
    command = map_get(check, "command")

    errors
    |> maybe_error(type not in @check_types, "#{path}.type must be http, tcp, script, or grpc")
    |> maybe_error(
      invalid_positive_ms?(map_get(check, "timeout_ms")),
      "#{path}.timeout_ms must be positive"
    )
    |> maybe_error(
      invalid_positive_ms?(map_get(check, "interval_ms")),
      "#{path}.interval_ms must be positive"
    )
    |> maybe_error(
      invalid_failures_before_critical?(map_get(check, "failures_before_critical")),
      "#{path}.failures_before_critical must be positive"
    )
    |> maybe_error(
      type in ["tcp", "grpc"] and invalid_port?(map_get(check, "port")),
      "#{path}.port must be 1..65535 or a template"
    )
    |> maybe_error(
      type == "script" and invalid_command?(command),
      "#{path}.command must be a safe command string or list"
    )
  end

  defp validate_check(errors, path, _check), do: ["#{path} must be an object" | errors]

  defp invalid_name?(value), do: not (is_binary(value) and Regex.match?(@name_pattern, value))

  defp invalid_port?(nil), do: false
  defp invalid_port?(value) when is_integer(value), do: value < 1 or value > 65_535

  defp invalid_port?(value) when is_binary(value) do
    cond do
      String.contains?(value, "${") -> false
      match?({_port, ""}, Integer.parse(value)) -> invalid_port?(String.to_integer(value))
      true -> true
    end
  end

  defp invalid_port?(_value), do: true

  defp invalid_positive_ms?(nil), do: false
  defp invalid_positive_ms?(value) when is_integer(value), do: value <= 0

  defp invalid_positive_ms?(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed <= 0
      _ -> true
    end
  end

  defp invalid_positive_ms?(_value), do: true

  defp invalid_failures_before_critical?(nil), do: false
  defp invalid_failures_before_critical?(value), do: invalid_positive_ms?(value)

  defp invalid_command?(command) when is_list(command),
    do: command == [] or not Enum.all?(command, &(is_binary(&1) and String.trim(&1) != ""))

  defp invalid_command?(command) when is_binary(command),
    do: String.trim(command) == "" or Regex.match?(@unsafe_command_pattern, command)

  defp invalid_command?(_command), do: true

  defp base_context(manifest, job_id, opts) do
    env = Keyword.get(opts, :env) || manifest_environment(manifest)

    config =
      Keyword.get(opts, :config) || config_from_env(env) || Keyword.get(opts, :config_from_bundle) ||
        %{}

    %{
      "job_id" => job_id,
      "graph_id" => Map.get(manifest, :graph_id),
      "job_name" => Map.get(manifest, :job_name),
      "node" => to_string(Node.self()),
      "env" => stringify_map(env),
      "config" => stringify_map(config),
      "bundle_root" => Keyword.get(opts, :bundle_root)
    }
  end

  defp manifest_environment(manifest) do
    manifest
    |> Map.get(:nodes, [])
    |> Enum.find_value(%{}, fn node ->
      node
      |> Map.get(:config, %{})
      |> map_get("environment")
      |> case do
        env when is_map(env) -> stringify_map(env)
        _ -> nil
      end
    end)
  end

  defp config_from_env(env) when is_map(env) do
    case Map.get(env, "MN_BLUEPRINT_CONFIG_JSON") do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, config} when is_map(config) -> config
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp config_from_env(_env), do: nil

  defp source_node_id(node) do
    get_in(node, [:config, "__mirror_neuron_source_node_id"]) || Map.get(node, :node_id)
  end

  defp coerce_resolved_port(service) do
    case parse_port(Map.get(service, "port")) do
      nil -> service
      port -> Map.put(service, "port", port)
    end
  end

  defp parse_port(value) when is_integer(value), do: value

  defp parse_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port >= 1 and port <= 65_535 -> port
      _ -> nil
    end
  end

  defp parse_port(_value), do: nil

  defp default_service_id(service, context) do
    [
      Map.get(context, "job_id"),
      Map.get(context, "agent_id") || "job",
      Map.get(service, "name")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp initial_status(%{"checks" => checks}) when is_list(checks) and checks != [],
    do: "warning"

  defp initial_status(_service), do: "passing"

  defp tags_match?(_service_tags, nil), do: true
  defp tags_match?(_service_tags, []), do: true

  defp tags_match?(service_tags, required_tags) do
    service_tags = service_tags |> list_strings() |> MapSet.new()
    required_tags = required_tags |> list_strings() |> MapSet.new()
    MapSet.subset?(required_tags, service_tags)
  end

  defp list_strings(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list_strings(nil), do: []
  defp list_strings(value), do: [to_string(value)]

  defp path_get(value, []), do: value

  defp path_get(value, [part | rest]) when is_map(value),
    do: value |> map_get(part) |> path_get(rest)

  defp path_get(_value, _parts), do: nil

  defp template_value(nil), do: ""
  defp template_value(value) when is_binary(value), do: value
  defp template_value(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors

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

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
