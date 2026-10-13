defmodule MirrorNeuron.Runtime.EventEnvelope do
  @moduledoc "Canonical mn.runtime.event.v1 metadata at the runtime publication boundary."

  def normalize(event, job_id) when is_map(event) do
    payload = value(event, :payload)
    payload = if is_map(payload), do: payload, else: %{}
    type = to_string(value(event, :type) || "event")

    metadata = %{
      schema: "mn.runtime.event.v1",
      event_id:
        value(event, :event_id) || value(payload, :event_id) ||
          Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      timestamp:
        value(event, :timestamp) || value(event, :ts) || value(payload, :timestamp) ||
          DateTime.to_iso8601(DateTime.utc_now()),
      job_id: value(event, :job_id) || job_id,
      level: level(event, payload, type),
      owner_blueprint:
        value(event, :owner_blueprint) || value(payload, :owner_blueprint) ||
          value(payload, :blueprint_id) || "",
      run_id: value(event, :run_id) || value(payload, :run_id) || "",
      step_id: value(event, :step_id) || value(payload, :step_id) || value(payload, :step) || "",
      agent_id:
        value(event, :agent_id) || value(payload, :agent_id) || value(payload, :worker) || "",
      activity_kind: kind(event, payload, type)
    }

    # Keep the caller's key style, including typed atom events used by subscribers.
    string_keys = Map.has_key?(event, "type")

    Enum.reduce(metadata, event, fn {key, item}, acc ->
      Map.put(acc, if(string_keys, do: Atom.to_string(key), else: key), item)
    end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp level(event, payload, type) do
    explicit = value(event, :level) || value(payload, :level) || value(event, :severity)

    normalized =
      if is_binary(explicit) or is_atom(explicit),
        do: explicit |> to_string() |> String.downcase(),
        else: ""

    cond do
      normalized in ["debug", "info", "warning", "error"] -> normalized
      String.contains?(type, ["failed", "error", "timed_out"]) -> "error"
      String.contains?(type, ["retry", "blocked", "timeout", "warning"]) -> "warning"
      true -> "info"
    end
  end

  defp kind(event, payload, type) do
    explicit = value(event, :activity_kind) || value(payload, :activity_kind)

    cond do
      explicit in ["action", "result", "finding", "milestone", "diagnostic"] -> explicit
      String.ends_with?(type, "started") -> "action"
      String.ends_with?(type, ["completed", "ready"]) -> "result"
      true -> "milestone"
    end
  end
end
