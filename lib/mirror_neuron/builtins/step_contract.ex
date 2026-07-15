defmodule MirrorNeuron.Builtins.StepContract do
  @moduledoc false

  def resolve_fields(fields, context) when is_map(fields) and is_map(context) do
    Map.new(fields, fn {key, value} -> {to_string(key), resolve(value, context)} end)
  end

  def resolve_fields(_fields, _context), do: %{}

  def validate_schema(value, schema) when is_map(schema) and map_size(schema) > 0 do
    required = Map.get(schema, "required", [])

    cond do
      Map.get(schema, "type") == "object" and not is_map(value) ->
        {:error, "step contract requires an object"}

      is_list(required) and is_map(value) ->
        missing = Enum.reject(required, &Map.has_key?(value, to_string(&1)))

        if missing == [] do
          :ok
        else
          {:error, "step contract is missing required fields: #{Enum.join(missing, ", ")}"}
        end

      true ->
        :ok
    end
  end

  def validate_schema(_value, _schema), do: :ok

  def artifacts(payload, message_artifacts) do
    payload_artifacts =
      case payload do
        %{"artifacts" => values} when is_list(values) -> values
        _ -> []
      end

    (payload_artifacts ++ List.wrap(message_artifacts))
    |> Enum.filter(&is_map/1)
    |> Enum.uniq()
  end

  def metadata(payload) when is_map(payload) do
    case Map.get(payload, "_mn_step") do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  def metadata(_payload), do: %{}

  def output_payload(%{"outputs" => outputs}) when is_map(outputs), do: outputs
  def output_payload(payload) when is_map(payload), do: payload
  def output_payload(_payload), do: %{}

  def initial_input_payload(payload) when is_map(payload) do
    Enum.find_value(["kwargs", "body", "payload", "data", "content", "input"], fn key ->
      case Map.get(payload, key) do
        nested when is_map(nested) -> initial_input_payload(nested)
        _ -> nil
      end
    end) || payload
  end

  def initial_input_payload(_payload), do: %{}

  defp resolve(%{"$ref" => "run_input"} = reference, context) do
    context
    |> Map.get("run_inputs", %{})
    |> resolve_path(Map.get(reference, "path", []))
  end

  defp resolve(%{"$ref" => "upstream", "step_id" => step_id} = reference, context) do
    context
    |> Map.get("upstream_outputs", %{})
    |> Map.get(to_string(step_id))
    |> resolve_path(Map.get(reference, "path", []))
  end

  defp resolve(%{"$ref" => "flow_output"} = reference, context) do
    context
    |> Map.get("flow_output", %{})
    |> resolve_path(Map.get(reference, "path", []))
  end

  defp resolve(value, context) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), resolve(item, context)} end)
  end

  defp resolve(value, context) when is_list(value), do: Enum.map(value, &resolve(&1, context))
  defp resolve(value, _context), do: value

  defp resolve_path(value, path) when is_list(path) do
    Enum.reduce(path, value, fn part, current ->
      if is_map(current), do: Map.get(current, to_string(part)), else: nil
    end)
  end

  defp resolve_path(value, _path), do: value
end
