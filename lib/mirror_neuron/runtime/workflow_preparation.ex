defmodule MirrorNeuron.Runtime.WorkflowPreparation do
  @moduledoc false

  # A preparation owns a fixed deadline; progress events cannot renew it.
  @max_timeout_ms 86_400_000
  @max_preparations 1_024
  @events ["runtime_preparation_started", "runtime_preparation_finished"]

  def event?(type), do: type in @events

  def on_event(state, step_id, agent_id, type, payload, now) do
    step = state["steps"][step_id]

    if state["status"] == "running" and authorized?(step, agent_id, payload) do
      update_ancestors(state, step_id, agent_id, type, payload, now, MapSet.new())
    else
      state
    end
  end

  defp update_ancestors(state, nil, _agent, _type, _payload, _now, _seen), do: state

  defp update_ancestors(state, id, agent, type, payload, now, seen) do
    step = state["steps"][id]

    if is_map(step) and step["status"] == "running" and not MapSet.member?(seen, id) do
      updated = step |> advance(now) |> change(agent, type, payload, now)
      state = put_in(state, ["steps", id], updated)

      update_ancestors(
        state,
        step["parent_step_id"],
        agent,
        type,
        payload,
        now,
        MapSet.put(seen, id)
      )
    else
      state
    end
  end

  def observe(step, agent_id, type, payload, now) do
    step = advance(step, now)

    if authorized?(step, agent_id, payload) do
      change(step, agent_id, type, payload, now)
    else
      step
    end
  end

  def advance(%{"preparation" => clock} = step, now) when is_map(clock) do
    active = clock["active"] || %{}
    current = millis(now)
    previous = clock["accounted_at"] || current

    until =
      active
      |> Map.values()
      |> Enum.map(& &1["deadline_ms"])
      |> Enum.min(fn -> previous end)
      |> min(current)

    elapsed = if map_size(active) > 0, do: max(until - previous, 0), else: 0

    if map_size(active) == 0 do
      step
    else
      step
      |> shift_execution_clocks(elapsed)
      |> Map.put("preparation", %{clock | "accounted_at" => max(current, previous)})
    end
  end

  def advance(step, _now), do: step

  def expired?(step, now) do
    step
    |> get_in(["preparation", "active"])
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.any?(&(&1["deadline_ms"] <= millis(now)))
  end

  def reset(step), do: Map.delete(step, "preparation")

  # Pausing stops the owning commands. Account their setup once and retire the
  # old scopes; a replacement worker must announce its own bounded preparation.
  def pause(step, now) do
    case advance(step, now) do
      %{"preparation" => clock} = updated ->
        Map.put(updated, "preparation", %{clock | "active" => %{}})

      updated ->
        updated
    end
  end

  defp authorized?(step, agent_id, payload) do
    step["status"] == "running" and agent_id in (step["agent_ids"] || []) and
      is_map(step["current_attempt"]) and
      payload["attempt_id"] == step["current_attempt"]["attempt_id"] and
      valid_id?(payload["preparation_id"])
  end

  defp change(step, agent_id, "runtime_preparation_started", payload, now) do
    clock =
      step["preparation"] || %{"active" => %{}, "seen" => %{}, "accounted_at" => millis(now)}

    id = payload["preparation_id"]
    timeout = payload["timeout_ms"]

    if payload["kind"] in ["model", "dependencies", "service"] and
         is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms and
         map_size(clock["seen"]) < @max_preparations and not Map.has_key?(clock["seen"], id) and
         not execution_expired?(step, now) do
      active =
        Map.put(clock["active"], id, %{
          "agent_id" => agent_id,
          "deadline_ms" => millis(now) + timeout
        })

      Map.put(step, "preparation", %{
        clock
        | "active" => active,
          "accounted_at" =>
            if(map_size(clock["active"]) == 0, do: millis(now), else: clock["accounted_at"]),
          "seen" => Map.put(clock["seen"], id, true)
      })
    else
      step
    end
  end

  defp change(step, agent_id, "runtime_preparation_finished", payload, now) do
    id = payload["preparation_id"]

    case get_in(step, ["preparation", "active", id]) do
      %{"agent_id" => ^agent_id, "deadline_ms" => deadline} ->
        if deadline > millis(now),
          do: update_in(step, ["preparation", "active"], &Map.delete(&1, id)),
          else: step

      _ ->
        step
    end
  end

  defp change(step, _agent_id, _type, _payload, _now), do: step

  defp shift_execution_clocks(step, elapsed) do
    keys = ["deadline_at", "progress_deadline_at"]

    keys =
      if step["heartbeat_uses_execution_budget"], do: ["heartbeat_deadline_at" | keys], else: keys

    step = shift(step, keys, elapsed)

    case step["current_attempt"] do
      attempt when is_map(attempt) ->
        Map.put(step, "current_attempt", shift(attempt, keys, elapsed))

      _ ->
        step
    end
  end

  defp shift(value, keys, elapsed) do
    Enum.reduce(keys, value, fn key, acc ->
      case acc[key] do
        timestamp when is_binary(timestamp) ->
          {:ok, time, _} = DateTime.from_iso8601(timestamp)
          Map.put(acc, key, time |> DateTime.add(elapsed, :millisecond) |> DateTime.to_iso8601())

        _ ->
          acc
      end
    end)
  end

  defp execution_expired?(%{"deadline_at" => deadline}, now) when is_binary(deadline),
    do: millis(deadline) <= millis(now)

  defp execution_expired?(_step, _now), do: false
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..128

  defp millis(timestamp) do
    {:ok, time, _} = DateTime.from_iso8601(timestamp)
    DateTime.to_unix(time, :millisecond)
  end
end
