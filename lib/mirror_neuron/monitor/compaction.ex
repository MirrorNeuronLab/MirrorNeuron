defmodule MirrorNeuron.Monitor.Compaction do
  @moduledoc "Bounds values and removes embedded payloads from public detail projections."

  @compact_string_bytes 8_192
  @compact_list_items 50
  @compact_job_drop_fields ["manifest", "result"]
  @compact_event_drop_fields [
    "input",
    "last_message",
    "messages",
    "output",
    "outputs",
    "result",
    "workflow_state"
  ]
  @compact_step_drop_fields ["last_message", "output"]

  def public_job(job, opts) do
    job = Map.drop(job, ["manifest"])

    if Keyword.get(opts, :compact, false) do
      compact_job(job)
    else
      job
    end
  end

  defp compact_job(job) do
    job
    |> Map.drop(@compact_job_drop_fields)
    |> Map.update("workflow_state", nil, &compact_workflow_state/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> compact_value()
  end

  defp compact_workflow_state(%{"steps" => steps} = state) when is_map(steps) do
    compact_steps =
      Map.new(steps, fn {step_id, step} ->
        compact_step =
          if is_map(step) do
            step
            |> Map.drop(@compact_step_drop_fields)
            |> maybe_put_staged_ref("output_ref", Map.get(step, "output"))
          else
            step
          end

        {step_id, compact_step}
      end)

    state
    |> Map.drop(["messages"])
    |> Map.put("steps", compact_steps)
  end

  defp compact_workflow_state(_state), do: nil

  def recent_events(events, limit, opts) when is_integer(limit) and limit > 0 do
    events
    |> Enum.reverse()
    |> Enum.take(limit)
    |> maybe_compact_values(opts)
  end

  def recent_events(events, _limit, opts),
    do: events |> Enum.reverse() |> maybe_compact_values(opts)

  defp maybe_compact_values(values, opts) do
    if Keyword.get(opts, :compact, false) do
      Enum.map(values, &compact_event/1)
    else
      values
    end
  end

  defp compact_event(event) when is_map(event) do
    event
    |> Map.drop(@compact_event_drop_fields)
    |> Map.update("payload", nil, &compact_event_payload/1)
    |> maybe_put_staged_ref("payload_ref", event_payload_candidate(event))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> compact_value()
  end

  defp compact_event(event), do: compact_value(event)

  defp compact_event_payload(payload) when is_map(payload) do
    payload
    |> Map.drop(@compact_event_drop_fields)
    |> Map.update("_mn_step", nil, fn
      metadata when is_map(metadata) -> Map.drop(metadata, ["run_inputs", "step_input"])
      _ -> nil
    end)
    |> maybe_put_staged_ref("payload_ref", event_payload_candidate(payload))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_event_payload(payload), do: compact_value(payload)

  defp event_payload_candidate(value) when is_map(value) do
    Map.get(value, "payload_ref") ||
      Map.get(value, "result_ref") ||
      Map.get(value, "workflow_state_ref") ||
      get_in(value, ["outputs", "_mn_staged_artifact"]) ||
      get_in(value, ["result", "_mn_staged_artifact"])
  end

  defp maybe_put_staged_ref(map, key, reference) when is_map(reference) do
    if Map.get(reference, "version") == "mn.staged_artifact/v1" do
      Map.put_new(map, key, reference)
    else
      map
    end
  end

  defp maybe_put_staged_ref(map, _key, _reference), do: map

  def compact_value(value) when is_binary(value) do
    value = if String.valid?(value), do: value, else: inspect(value)

    if byte_size(value) > @compact_string_bytes do
      prefix = value |> binary_part(0, @compact_string_bytes) |> trim_partial_codepoint()
      prefix <> "\n[truncated #{byte_size(value) - byte_size(prefix)} bytes]"
    else
      value
    end
  end

  def compact_value(value) when is_list(value) do
    compacted =
      value
      |> Enum.take(@compact_list_items)
      |> Enum.map(&compact_value/1)

    if length(value) > @compact_list_items do
      compacted ++ [%{"truncated_items" => length(value) - @compact_list_items}]
    else
      compacted
    end
  end

  def compact_value(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, child} -> {key, compact_value(child)} end)
  end

  def compact_value(value), do: value

  defp trim_partial_codepoint(text) do
    if String.valid?(text),
      do: text,
      else: text |> binary_part(0, byte_size(text) - 1) |> trim_partial_codepoint()
  end
end
