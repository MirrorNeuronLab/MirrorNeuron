defmodule MirrorNeuron.Runtime.LiveInput do
  @moduledoc """
  Resolves and delivers manifest-declared input commands to active runs.

  Callers name only a public live-input ID. The target entrypoint and message
  type always come from the run's immutable manifest.
  """

  alias MirrorNeuron.Persistence.RedisStore

  @active_statuses ["pending", "running"]
  @max_payload_bytes 16_384
  @max_idempotency_key_bytes 200
  @input_id_pattern ~r/^[a-z][a-z0-9_]{0,63}$/

  def max_payload_bytes, do: @max_payload_bytes

  def send(run_id, input_id, payload, idempotency_key) do
    with :ok <- validate_identifier(run_id, "run_id"),
         :ok <- validate_input_id(input_id),
         :ok <- validate_idempotency_key(idempotency_key),
         {:ok, run} <- RedisStore.fetch_job(run_id),
         :ok <- ensure_active(run),
         {:ok, declaration} <- resolve_contract(run, input_id),
         schema <- Map.get(declaration, "schema", %{}),
         {:ok, normalized_payload} <- validate_payload(payload, schema),
         message <- build_message(input_id, declaration, normalized_payload, idempotency_key),
         {:ok, _status} <-
           MirrorNeuron.send_message(run_id, declaration["entrypoint"], message) do
      {:ok,
       %{
         "run_id" => run_id,
         "input_id" => input_id,
         "command_id" => idempotency_key,
         "status" => "accepted"
       }}
    end
  end

  @doc false
  def resolve_contract(run, input_id) when is_map(run) and is_binary(input_id) do
    manifest = Map.get(run, "manifest", %{})
    live_inputs = get_in(manifest, ["contract", "live_inputs"])

    with declaration when is_map(declaration) <- map_value(live_inputs, input_id),
         entrypoint when is_binary(entrypoint) <- declaration["entrypoint"],
         true <- entrypoint in declared_entrypoints(manifest),
         message_type when is_binary(message_type) <- declaration["message_type"],
         true <- declared_route?(manifest, entrypoint, message_type) do
      {:ok, declaration}
    else
      nil -> {:error, {:invalid_live_input, "input #{input_id} is not declared"}}
      false -> {:error, {:invalid_live_input, "declared live input route is not permitted"}}
      _ -> {:error, {:invalid_live_input, "live input declaration is invalid"}}
    end
  end

  def resolve_contract(_run, input_id),
    do: {:error, {:invalid_live_input, "input #{input_id} is not declared"}}

  @doc false
  def validate_payload(payload, schema) when is_map(payload) and is_map(schema) do
    validate_value(payload, schema, "$")
  end

  def validate_payload(_payload, _schema),
    do: {:error, {:invalid_live_input, "payload must be a JSON object"}}

  defp ensure_active(%{"status" => status}) when status in @active_statuses, do: :ok

  defp ensure_active(%{"status" => status}),
    do: {:error, {:inactive_run, status || "unknown"}}

  defp ensure_active(_run), do: {:error, {:inactive_run, "unknown"}}

  defp validate_identifier(value, field) when is_binary(value) do
    if String.trim(value) == "",
      do: {:error, {:invalid_live_input, "#{field} is required"}},
      else: :ok
  end

  defp validate_identifier(_value, field),
    do: {:error, {:invalid_live_input, "#{field} is required"}}

  defp validate_input_id(input_id) when is_binary(input_id) do
    if Regex.match?(@input_id_pattern, input_id),
      do: :ok,
      else: {:error, {:invalid_live_input, "input_id is invalid"}}
  end

  defp validate_input_id(_input_id),
    do: {:error, {:invalid_live_input, "input_id is invalid"}}

  defp validate_idempotency_key(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, {:invalid_live_input, "idempotency_key is required"}}

      byte_size(trimmed) > @max_idempotency_key_bytes ->
        {:error, {:invalid_live_input, "idempotency_key is too long"}}

      true ->
        :ok
    end
  end

  defp validate_idempotency_key(_value),
    do: {:error, {:invalid_live_input, "idempotency_key is required"}}

  defp build_message(input_id, declaration, payload, idempotency_key) do
    %{
      "message_id" => idempotency_key,
      "type" => declaration["message_type"],
      "class" => "command",
      "payload" => payload,
      "headers" => %{
        "mn.live_input_id" => input_id,
        "mn.idempotency_key" => idempotency_key
      }
    }
  end

  defp declared_entrypoints(manifest) do
    Map.get(manifest, "entrypoints") ||
      get_in(manifest, ["agents", "entrypoints"]) ||
      []
  end

  defp declared_route?(manifest, entrypoint, message_type) do
    edges =
      Map.get(manifest, "edges") ||
        get_in(manifest, ["agents", "edges"]) ||
        get_in(manifest, ["flow", "edges"]) ||
        []

    Enum.any?(edges, fn edge ->
      is_map(edge) and
        (edge["from_node"] || edge["from"]) == entrypoint and
        edge["message_type"] == message_type
    end)
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  defp validate_value(value, schema, path) do
    with :ok <- validate_enum(value, schema, path),
         :ok <- validate_type(value, schema["type"], path) do
      validate_typed_value(value, schema, path)
    end
  end

  defp validate_enum(value, %{"enum" => allowed}, path) when is_list(allowed) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_live_input, "#{path} is not an allowed value"}}
  end

  defp validate_enum(_value, _schema, _path), do: :ok

  defp validate_type(_value, nil, _path), do: :ok
  defp validate_type(value, "object", _path) when is_map(value), do: :ok
  defp validate_type(value, "array", _path) when is_list(value), do: :ok
  defp validate_type(value, "string", _path) when is_binary(value), do: :ok
  defp validate_type(value, "boolean", _path) when is_boolean(value), do: :ok
  defp validate_type(value, "integer", _path) when is_integer(value), do: :ok
  defp validate_type(value, "number", _path) when is_number(value), do: :ok
  defp validate_type(nil, "null", _path), do: :ok

  defp validate_type(_value, type, path),
    do: {:error, {:invalid_live_input, "#{path} must be #{type}"}}

  defp validate_typed_value(value, %{"type" => "object"} = schema, path),
    do: validate_object(value, schema, path)

  defp validate_typed_value(value, %{"type" => "array"} = schema, path),
    do: validate_array(value, schema, path)

  defp validate_typed_value(value, %{"type" => "string"} = schema, path),
    do: validate_string(value, schema, path)

  defp validate_typed_value(value, schema, path) when is_number(value),
    do: validate_number(value, schema, path)

  defp validate_typed_value(value, schema, path) when is_map(value),
    do: validate_object(value, schema, path)

  defp validate_typed_value(value, schema, path) when is_list(value),
    do: validate_array(value, schema, path)

  defp validate_typed_value(value, schema, path) when is_binary(value),
    do: validate_string(value, schema, path)

  defp validate_typed_value(value, _schema, _path), do: {:ok, value}

  defp validate_object(value, schema, path) when is_map(value) do
    properties = if is_map(schema["properties"]), do: schema["properties"], else: %{}

    with :ok <- validate_extra_properties(value, properties, schema, path),
         value <- apply_property_defaults(value, properties),
         :ok <- validate_required(value, schema["required"], path) do
      Enum.reduce_while(properties, {:ok, value}, fn {key, property_schema}, {:ok, acc} ->
        case Map.fetch(acc, key) do
          :error ->
            {:cont, {:ok, acc}}

          {:ok, property_value} ->
            case validate_value(property_value, property_schema, "#{path}.#{key}") do
              {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
              {:error, _reason} = error -> {:halt, error}
            end
        end
      end)
    end
  end

  defp validate_object(_value, _schema, path),
    do: {:error, {:invalid_live_input, "#{path} must be object"}}

  defp validate_extra_properties(value, properties, %{"additionalProperties" => false}, path) do
    extra = Map.keys(value) -- Map.keys(properties)

    if extra == [],
      do: :ok,
      else:
        {:error,
         {:invalid_live_input, "#{path} contains unknown fields: #{Enum.join(extra, ", ")}"}}
  end

  defp validate_extra_properties(_value, _properties, _schema, _path), do: :ok

  defp apply_property_defaults(value, properties) do
    Enum.reduce(properties, value, fn {key, property_schema}, acc ->
      if not Map.has_key?(acc, key) and is_map(property_schema) and
           Map.has_key?(property_schema, "default") do
        Map.put(acc, key, property_schema["default"])
      else
        acc
      end
    end)
  end

  defp validate_required(_value, required, _path) when not is_list(required), do: :ok

  defp validate_required(value, required, path) do
    missing = required |> Enum.map(&to_string/1) |> Enum.reject(&Map.has_key?(value, &1))

    if missing == [],
      do: :ok,
      else:
        {:error,
         {:invalid_live_input, "#{path} is missing required fields: #{Enum.join(missing, ", ")}"}}
  end

  defp validate_array(value, schema, path) when is_list(value) do
    max_items = schema["maxItems"]

    if is_integer(max_items) and length(value) > max_items do
      {:error, {:invalid_live_input, "#{path} has too many items"}}
    else
      item_schema = if is_map(schema["items"]), do: schema["items"], else: %{}

      value
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
        case validate_value(item, item_schema, "#{path}[#{index}]") do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    end
  end

  defp validate_array(_value, _schema, path),
    do: {:error, {:invalid_live_input, "#{path} must be array"}}

  defp validate_string(value, schema, path) when is_binary(value) do
    length = String.length(value)

    cond do
      is_integer(schema["maxLength"]) and length > schema["maxLength"] ->
        {:error, {:invalid_live_input, "#{path} is too long"}}

      is_integer(schema["minLength"]) and length < schema["minLength"] ->
        {:error, {:invalid_live_input, "#{path} is too short"}}

      true ->
        {:ok, value}
    end
  end

  defp validate_string(_value, _schema, path),
    do: {:error, {:invalid_live_input, "#{path} must be string"}}

  defp validate_number(value, schema, path) do
    cond do
      is_number(schema["maximum"]) and value > schema["maximum"] ->
        {:error, {:invalid_live_input, "#{path} is above the maximum"}}

      is_number(schema["minimum"]) and value < schema["minimum"] ->
        {:error, {:invalid_live_input, "#{path} is below the minimum"}}

      true ->
        {:ok, value}
    end
  end
end
