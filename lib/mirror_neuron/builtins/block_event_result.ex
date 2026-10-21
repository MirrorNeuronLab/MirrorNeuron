defmodule MirrorNeuron.Builtins.BlockEventResult do
  @moduledoc false
  @version "mn.block_events/v1"
  @state_version "mn.block_event_state/v1"
  @reference_keys ~w(type version kind path sha256 size_bytes)
  @result_keys ~w(version delivery_key previous next emissions reference handoff)
  @payload_keys ~w(outputs artifacts metrics status events event_result publication workflow_step_id run_id runtime_step_mode)

  def validate_config(nil), do: :ok

  def validate_config(%{"version" => @version, "ports" => ports, "event_types" => events} = value)
      when is_map(ports) and is_list(events) do
    if Enum.sort(Map.keys(value)) == ~w(event_types ports version) and
         map_size(ports) <= 32 and length(events) <= 128 and
         Enum.all?(ports, fn {key, value} -> identifier?(key) and identifier?(value) end) and
         Enum.all?(events, &identifier?/1) and Enum.uniq(events) == events do
      :ok
    else
      error("invalid event binding")
    end
  end

  def validate_config(_), do: error("unsupported or invalid event binding")

  def interpret(payload, current_state, config) do
    binding = config["block_event"]
    result = payload["event_result"]

    with :ok <- validate_payload(payload),
         :ok <- required_binding(binding),
         :ok <- validate_config(binding),
         :ok <- validate_result(result),
         :ok <- state_matches(current_state, result),
         {:ok, emissions} <- emissions(result["emissions"], binding, result["delivery_key"]),
         {:ok, events} <- events(payload["events"], binding) do
      state = %{"version" => @state_version, "reference" => result["next"]}
      state = if result["handoff"], do: Map.put(state, "handoff", result["handoff"]), else: state
      {:ok, state, emissions, events}
    end
  end

  defp validate_payload(payload) do
    if Enum.all?(Map.keys(payload), &(&1 in @payload_keys)) and
         byte_size(Jason.encode!(payload)) <= 4_194_304,
       do: :ok,
       else: error("invalid or oversized event envelope")
  end

  defp required_binding(nil), do: error("event result requires a declared event binding")
  defp required_binding(_), do: :ok

  defp validate_result(%{"version" => @version} = value) do
    required = @result_keys -- ["handoff"]
    next = value["next"]
    reference = value["reference"]

    if Enum.all?(required, &Map.has_key?(value, &1)) and
         Enum.all?(Map.keys(value), &(&1 in @result_keys)) and
         identifier?(value["delivery_key"], 256) and
         reference?(next, "block_event_state") and
         reference?(reference, "block_result") and
         Path.dirname(next["path"]) == Path.dirname(reference["path"]) and
         Path.basename(reference["path"]) == "result.json" and
         (is_nil(value["previous"]) or reference?(value["previous"], "block_event_state")) and
         valid_handoff?(value["handoff"], reference) do
      :ok
    else
      error("invalid event result")
    end
  end

  defp validate_result(_), do: error("unsupported event result version")

  defp state_matches(state, %{"previous" => nil}) when state == %{}, do: :ok

  defp state_matches(%{"version" => @state_version, "reference" => reference}, result) do
    if reference == result["previous"] or reference == result["next"],
      do: :ok,
      else: error("stale event transition cannot replace current state")
  end

  defp state_matches(_, _), do: error("event state does not match the admitted transition")

  defp emissions(values, binding, delivery) when is_list(values) and length(values) <= 32 do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, result} ->
      if is_map(item) and Enum.all?(Map.keys(item), &(&1 in ~w(port value artifacts))) and
           is_map(item["value"]) and Map.has_key?(binding["ports"], item["port"]) and
           is_list(Map.get(item, "artifacts", [])) and
           length(Map.get(item, "artifacts", [])) <= 64 do
        emission = %{
          "type" => binding["ports"][item["port"]],
          "body" => item["value"],
          "artifacts" => Map.get(item, "artifacts", []),
          "headers" => %{"mn.idempotency_key" => "block-event:#{delivery}:#{index}"}
        }

        {:cont, {:ok, [emission | result]}}
      else
        {:halt, error("invalid or undeclared event emission")}
      end
    end)
    |> reverse_result()
  end

  defp emissions(_, _, _), do: error("event emission limit exceeded")

  defp events(values, binding) when is_list(values) and length(values) <= 128 do
    if Enum.all?(values, fn item ->
         is_map(item) and Enum.sort(Map.keys(item)) == ~w(payload type) and
           item["type"] in binding["event_types"] and is_map(item["payload"])
       end),
       do: {:ok, values},
       else: error("invalid or undeclared event observation")
  end

  defp events(_, _), do: error("event observation limit exceeded")

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error

  defp reference?(value, kind) when is_map(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@reference_keys) and
      value["type"] == "artifact_ref" and value["version"] == "mn.committed_json/v1" and
      value["kind"] == kind and is_integer(value["size_bytes"]) and
      value["size_bytes"] in 0..67_108_864 and is_binary(value["sha256"]) and
      Regex.match?(~r/^[a-f0-9]{64}$/, value["sha256"]) and safe_path?(value["path"])
  end

  defp reference?(_, _), do: false

  defp safe_path?(value) when is_binary(value) do
    String.starts_with?(value, "blocks/") and
      Regex.match?(~r/^[A-Za-z0-9_.\/-]+$/, value) and
      not Enum.any?(String.split(value, "/"), &(&1 in ["", ".", ".."]))
  end

  defp safe_path?(_), do: false
  defp identifier?(value, maximum \\ 128)

  defp identifier?(value, maximum) when is_binary(value),
    do: byte_size(value) <= maximum and Regex.match?(~r/^[A-Za-z0-9_:-]+$/, value)

  defp identifier?(_, _), do: false

  defp valid_handoff?(nil, _), do: true

  defp valid_handoff?(
         %{
           "type" => "block_artifact_bundle",
           "version" => "mn.block_handoff/v1",
           "value" => reference
         },
         reference
       ),
       do: true

  defp valid_handoff?(_, _), do: false
  defp error(message), do: {:error, %{"error" => message, "retryable" => false}}
end
