defmodule MirrorNeuron.Manifest.ResponseService do
  @moduledoc "Validates the bounded response agent tool, memory and operation contract."

  alias MirrorNeuron.Runtime.ResponseAgentSpec
  alias MirrorNeuron.Manifest.Values

  def validate_response_service(errors, %{response_service: nil}), do: errors

  def validate_response_service(errors, %{response_service: response_service})
      when is_map(response_service) do
    unknown = Map.keys(response_service) -- ["enabled", "agent"]

    errors
    |> Values.maybe_add_error(
      response_service["enabled"] !== true,
      "response_service.enabled must be the literal boolean true"
    )
    |> Values.maybe_add_error(
      unknown != [],
      "response_service accepts only enabled and agent"
    )
    |> Values.add_errors(validate_response_agent(response_service["agent"]))
  end

  def validate_response_service(errors, _manifest) do
    ["response_service must be an object" | errors]
  end

  defp validate_response_agent(nil), do: []

  defp validate_response_agent(agent) when is_map(agent) do
    service = if is_map(agent["service"]), do: agent["service"], else: %{}
    tools = if is_map(agent["tools"]), do: agent["tools"], else: %{}
    user_tools = if is_map(tools["user"]), do: tools["user"], else: %{}
    internal_tools = if is_map(tools["internal"]), do: tools["internal"], else: %{}
    operations = if is_map(agent["operations"]), do: agent["operations"], else: %{}
    memory = if is_map(agent["memory"]), do: agent["memory"], else: %{}

    []
    |> Values.maybe_add_error(
      not ResponseAgentSpec.valid_keys?(Map.keys(agent)),
      "response_service.agent must contain kind, service, tools, operations, and memory, with optional preflight, manual_content, and activity"
    )
    |> Values.maybe_add_error(
      agent["kind"] != "bounded_mcp",
      "response_service.agent.kind must be bounded_mcp"
    )
    |> Values.maybe_add_error(
      MapSet.new(Map.keys(service)) != MapSet.new(~w(name path required_tags)) or
        not Values.nonempty_string?(service["name"]) or not safe_mcp_path?(service["path"]) or
        not nonempty_unique_strings?(service["required_tags"]),
      "response_service.agent.service must declare an exact name, path, and required_tags"
    )
    |> Values.maybe_add_error(
      MapSet.new(Map.keys(tools)) != MapSet.new(~w(user internal)) or user_tools == %{} or
        internal_tools == %{},
      "response_service.agent.tools must contain non-empty user and internal tool maps"
    )
    |> Values.add_errors(validate_response_agent_tools(user_tools, true))
    |> Values.add_errors(validate_response_agent_tools(internal_tools, false))
    |> Values.maybe_add_error(
      MapSet.size(
        MapSet.intersection(
          MapSet.new(Map.keys(user_tools)),
          MapSet.new(Map.keys(internal_tools))
        )
      ) > 0,
      "response_service.agent user and internal tool names must be distinct"
    )
    |> Values.add_errors(validate_response_agent_preflight(agent, user_tools))
    |> Values.add_errors(
      validate_response_agent_operations(operations, user_tools, internal_tools)
    )
    |> Values.add_errors(ResponseAgentSpec.projection_errors(agent, internal_tools))
    |> Values.maybe_add_error(
      MapSet.new(Map.keys(memory)) != MapSet.new(~w(enabled mode path types max_active_records)) or
        memory["enabled"] !== true or memory["mode"] != "explicit" or
        not safe_relative_path?(memory["path"]) or
        not safe_memory_types?(memory["types"]) or
        not (is_integer(memory["max_active_records"]) and memory["max_active_records"] in 1..500),
      "response_service.agent.memory must declare bounded explicit Job memory"
    )
  end

  defp validate_response_agent(_agent), do: ["response_service.agent must be an object"]

  defp validate_response_agent_preflight(agent, user_tools) do
    if Map.has_key?(agent, "preflight") do
      validate_response_agent_preflight_contract(agent["preflight"], user_tools)
    else
      []
    end
  end

  defp validate_response_agent_preflight_contract(preflight, user_tools)
       when is_map(preflight) do
    expected = MapSet.new(~w(required_for_effects tool arguments required_result))
    effects = preflight["required_for_effects"]
    tool_name = preflight["tool"]
    arguments = preflight["arguments"]
    required_result = preflight["required_result"]

    declared_tool =
      case Map.get(user_tools, tool_name) do
        value when is_map(value) -> value
        _value -> %{}
      end

    declared_arguments = Map.get(declared_tool, "arguments")

    valid =
      MapSet.new(Map.keys(preflight)) == expected and
        nonempty_unique_strings?(effects) and
        MapSet.subset?(
          MapSet.new(effects),
          MapSet.new(Enum.map(user_tools, fn {_name, tool} -> tool["effect"] end))
        ) and
        Values.nonempty_string?(tool_name) and declared_tool["effect"] == "read" and
        is_map(arguments) and is_map(declared_arguments) and
        MapSet.new(Map.keys(arguments)) == MapSet.new(Map.keys(declared_arguments)) and
        is_map(required_result) and map_size(required_result) > 0 and
        Enum.all?(required_result, fn {key, value} ->
          Values.nonempty_string?(key) and safe_preflight_scalar?(value)
        end)

    if valid,
      do: [],
      else: ["response_service.agent.preflight must declare a bounded live read check"]
  end

  defp validate_response_agent_preflight_contract(_preflight, _user_tools),
    do: ["response_service.agent.preflight must declare a bounded live read check"]

  defp validate_response_agent_tools(tools, user?) do
    Enum.flat_map(tools, fn {name, specification} ->
      allowed = if user?, do: ~w(arguments effect description), else: ~w(arguments description)

      arguments =
        if is_map(specification) and is_map(specification["arguments"]),
          do: specification["arguments"],
          else: nil

      []
      |> Values.maybe_add_error(
        not Values.nonempty_string?(name),
        "response_service.agent tool names must be non-empty strings"
      )
      |> Values.maybe_add_error(
        not is_map(specification) or Map.keys(specification) -- allowed != [] or
          is_nil(arguments),
        "response_service.agent tool declarations have invalid fields"
      )
      |> Values.maybe_add_error(
        user? and is_map(specification) and
          not safe_contract_identifier?(specification["effect"]),
        "response_service.agent user tool effects must be safe lowercase identifiers"
      )
      |> Values.maybe_add_error(
        is_map(specification) and Map.has_key?(specification, "description") and
          not valid_tool_description?(specification["description"]),
        "response_service.agent tool descriptions must be non-empty strings of at most 1200 characters"
      )
      |> Values.add_errors(validate_response_agent_arguments(arguments || %{}))
    end)
  end

  defp valid_tool_description?(description) when is_binary(description) do
    length = description |> String.trim() |> String.to_charlist() |> length()
    length in 1..1200
  end

  defp valid_tool_description?(_description), do: false

  defp validate_response_agent_arguments(arguments) do
    Enum.flat_map(arguments, fn {name, schema} ->
      if Values.nonempty_string?(name) and ResponseAgentSpec.valid_argument_schema?(schema),
        do: [],
        else: ["response_service.agent tool arguments must declare scalar or enum schemas"]
    end)
  end

  defp validate_response_agent_operations(operations, user_tools, internal_tools)
       when map_size(operations) > 0 do
    Enum.flat_map(operations, fn {tool_name, operation} ->
      declared_tool = Values.nonempty_string?(get_in(user_tools, [tool_name, "effect"]))

      poll_tool = if is_map(operation), do: operation["poll_tool"], else: nil
      poll_arguments = get_in(internal_tools, [poll_tool, "arguments"]) || %{}

      valid =
        declared_tool and is_map(operation) and
          ResponseAgentSpec.valid_operation_keys?(Map.keys(operation)) and
          Map.has_key?(internal_tools, poll_tool) and
          Values.nonempty_string?(operation["id_field"]) and
          Values.nonempty_string?(operation["poll_argument"]) and
          Map.has_key?(poll_arguments, operation["poll_argument"]) and
          ResponseAgentSpec.valid_poll_arguments?(operation, poll_arguments) and
          is_integer(operation["poll_interval_ms"]) and
          operation["poll_interval_ms"] in 250..10_000 and
          is_integer(operation["timeout_seconds"]) and operation["timeout_seconds"] in 1..600

      if valid,
        do: [],
        else: [
          "response_service.agent operations must correlate declared user tools with internal polling tools"
        ]
    end)
  end

  defp validate_response_agent_operations(_operations, _user_tools, _internal_tools),
    do: ["response_service.agent.operations must be a non-empty object"]

  defp nonempty_unique_strings?(value) when is_list(value) and value != [] do
    Enum.all?(value, &Values.nonempty_string?/1) and length(value) == length(Enum.uniq(value))
  end

  defp nonempty_unique_strings?(_value), do: false

  defp safe_preflight_scalar?(value),
    do: is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value)

  defp safe_mcp_path?(value),
    do:
      Values.nonempty_string?(value) and String.starts_with?(value, "/") and
        not String.contains?(value, "://")

  defp safe_relative_path?(value) do
    Values.nonempty_string?(value) and Path.type(value) == :relative and
      ".." not in Path.split(value)
  end

  defp safe_memory_types?(value) do
    nonempty_unique_strings?(value) and Enum.all?(value, &safe_contract_identifier?/1)
  end

  defp safe_contract_identifier?(value) do
    Values.nonempty_string?(value) and String.length(value) <= 80 and
      Regex.match?(~r/^[a-z][a-z0-9_]*$/, value)
  end
end
