defmodule MirrorNeuron.Runtime.RunClock do
  @moduledoc "Persisted running intervals; queued, paused and recovery gaps are excluded."

  def advance(previous, current) do
    old = previous || %{}
    clock = get(old, "running_time")
    now = get(current, "updated_at")
    session = get(current, "clock_session")
    same_session = session != nil and session == get(old, "clock_session")
    was_running = get(old, "status") == "running"
    running = get(current, "status") == "running"
    prior_ms = if is_map(clock), do: clock["accumulated_ms"] || 0, else: 0
    active = if is_map(clock), do: clock["active_since"], else: nil
    # On process replacement only the last durable observation is measured.
    stop = if same_session, do: now, else: get(old, "updated_at")
    delta = if was_running and active, do: elapsed(active, stop), else: 0

    complete =
      if is_map(clock),
        do: clock["complete"] == true and not (was_running and not same_session),
        else: map_size(old) == 0 and not running

    %{
      "accumulated_ms" => prior_ms + delta,
      "active_since" => if(running, do: now, else: nil),
      "complete" => complete
    }
  end

  defp elapsed(a, b) do
    with {:ok, start, _} <- DateTime.from_iso8601(to_string(a)),
         {:ok, stop, _} <- DateTime.from_iso8601(to_string(b)) do
      max(DateTime.diff(stop, start, :millisecond), 0)
    else
      _ -> 0
    end
  end

  defp get(map, key),
    do: Map.get(map, key) || Enum.find_value(map, fn {k, v} -> if to_string(k) == key, do: v end)
end
