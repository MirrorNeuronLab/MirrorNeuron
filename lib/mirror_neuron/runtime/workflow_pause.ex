defmodule MirrorNeuron.Runtime.WorkflowPause do
  @moduledoc false

  @clocks ["deadline_at", "heartbeat_deadline_at", "retry_at"]
  @active ["queued", "running", "retry_wait", "waiting"]

  def pause(state, now), do: Map.put_new(state, "paused_at", now)

  def resume(state, now) do
    with paused_at when is_binary(paused_at) <- state["paused_at"],
         {:ok, paused, _} <- DateTime.from_iso8601(paused_at),
         {:ok, resumed, _} <- DateTime.from_iso8601(now) do
      elapsed = max(DateTime.diff(resumed, paused, :millisecond), 0)

      state
      |> Map.update!("steps", fn steps ->
        Map.new(steps, fn {id, step} ->
          {id, if(step["status"] in @active, do: shift_step(step, elapsed), else: step)}
        end)
      end)
      |> Map.delete("paused_at")
    else
      _ -> Map.delete(state, "paused_at")
    end
  end

  defp shift_step(step, elapsed) do
    step = shift_clocks(step, elapsed)

    case step["current_attempt"] do
      attempt when is_map(attempt) ->
        Map.put(step, "current_attempt", shift_clocks(attempt, elapsed))

      _ ->
        step
    end
  end

  defp shift_clocks(value, elapsed) do
    Enum.reduce(@clocks, value, fn key, acc ->
      case Map.get(acc, key) do
        timestamp when is_binary(timestamp) ->
          case DateTime.from_iso8601(timestamp) do
            {:ok, time, _} ->
              Map.put(
                acc,
                key,
                time |> DateTime.add(elapsed, :millisecond) |> DateTime.to_iso8601()
              )

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end
end
