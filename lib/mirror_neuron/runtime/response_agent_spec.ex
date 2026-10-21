defmodule MirrorNeuron.Runtime.ResponseAgentSpec do
  @moduledoc "Admission checks for SDK-derived bounded MCP response bindings."

  def valid_keys?(keys) do
    required = MapSet.new(~w(kind service tools operations memory))
    allowed = MapSet.union(required, MapSet.new(~w(preflight manual_content activity)))
    actual = MapSet.new(keys)
    MapSet.subset?(required, actual) and MapSet.subset?(actual, allowed)
  end

  def projection_errors(agent, internal_tools) do
    manual_errors =
      if not Map.has_key?(agent, "manual_content") or
           (is_binary(agent["manual_content"]) and String.valid?(agent["manual_content"]) and
              byte_size(agent["manual_content"]) <= 65_536),
         do: [],
         else: ["response_service.agent.manual_content must contain at most 65536 UTF-8 bytes"]

    activity_errors =
      if not Map.has_key?(agent, "activity") or
           (agent["activity"] == %{"tool" => "watch_job_activity"} and
              get_in(internal_tools, ["watch_job_activity", "arguments"]) == %{
                "after_event_id" => %{"type" => "string"},
                "wait_seconds" => %{"type" => "number"}
              }),
         do: [],
         else: ["response_service.agent.activity must bind the declared Job activity watch"]

    manual_errors ++ activity_errors
  end

  def valid_argument_schema?(schema) when is_map(schema) do
    type = Map.get(schema, "type", "string")
    enum = schema["enum"]

    Map.keys(schema) -- ~w(type enum) == [] and
      type in ~w(string boolean integer number) and
      (Map.has_key?(schema, "type") or Map.has_key?(schema, "enum")) and
      (not Map.has_key?(schema, "enum") or
         (is_list(enum) and enum != [] and length(enum) == length(Enum.uniq(enum)) and
            Enum.all?(enum, &scalar_type?(&1, type))))
  end

  def valid_argument_schema?(_schema), do: false

  def valid_operation_keys?(keys) do
    required = MapSet.new(~w(id_field poll_tool poll_argument poll_interval_ms timeout_seconds))
    actual = MapSet.new(keys)

    MapSet.subset?(required, actual) and
      MapSet.subset?(actual, MapSet.put(required, "poll_arguments"))
  end

  def valid_poll_arguments?(operation, declared) do
    arguments = Map.get(operation, "poll_arguments", %{})

    is_map(arguments) and is_map(declared) and
      not Map.has_key?(arguments, operation["poll_argument"]) and
      Enum.all?(arguments, fn {name, value} ->
        schema = declared[name]

        valid_argument_schema?(schema) and
          scalar_type?(value, Map.get(schema, "type", "string")) and
          (not Map.has_key?(schema, "enum") or value in schema["enum"])
      end)
  end

  defp scalar_type?(value, "string"), do: is_binary(value) and String.trim(value) != ""
  defp scalar_type?(value, "boolean"), do: is_boolean(value)
  defp scalar_type?(value, "integer"), do: is_integer(value)
  defp scalar_type?(value, "number"), do: is_number(value)
end
