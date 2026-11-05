defmodule MirrorNeuron.Runtime.WorkflowSupervision do
  @moduledoc false
  @inspection_ms 10_000
  @retry_ms 30_000

  def request(step, now) do
    case step["inspection"] do
      %{"deadline_at" => deadline} ->
        if millis(now) >= millis(deadline),
          do: {:failed, "workflow step inspection timed out"},
          else: :pending

      _ ->
        token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

        inspection = %{
          "id" => token,
          "attempt_id" => get_in(step, ["current_attempt", "attempt_id"]),
          "deadline_at" => after_ms(now, @inspection_ms)
        }

        {:inspect, Map.put(step, "inspection", inspection), token}
    end
  end

  def agents(state, step) do
    children =
      Enum.filter(
        Map.values(state["steps"]),
        &(&1["parent_step_id"] == step["id"] and &1["status"] == "running")
      )

    if children == [],
      do: step["agent_ids"] || [],
      else: Enum.flat_map(children, &agents(state, &1)) |> Enum.uniq()
  end

  def resolve(state, step, token, observations, now) do
    with "running" <- state["status"],
         "running" <- step["status"],
         %{"id" => ^token, "attempt_id" => attempt} <- step["inspection"],
         ^attempt <- get_in(step, ["current_attempt", "attempt_id"]) do
      step = Map.delete(step, "inspection")
      agents = agents(state, step)
      statuses = Enum.map(agents, &Map.get(observations, &1, "unknown"))
      evidence = evidence_until(state, step, now)

      cond do
        statuses == [] or "dead" in statuses ->
          {:failed, "workflow step worker is no longer running"}

        "unknown" in statuses and step["inspection_retry_used"] != true ->
          {:continued,
           step |> extend(after_ms(now, @retry_ms)) |> Map.put("inspection_retry_used", true),
           "worker inspection unavailable; bounded recheck"}

        "unknown" in statuses ->
          {:failed, "workflow step worker inspection unavailable"}

        is_binary(evidence) and millis(evidence) > millis(now) ->
          {:continued, step |> extend(evidence) |> Map.delete("inspection_retry_used"),
           "verified work progress or bounded wait"}

        true ->
          {:failed,
           if(is_nil(step["deadline_at"]),
             do: "workflow step progress deadline exceeded",
             else: "workflow step deadline exceeded"
           )}
      end
    else
      _ -> :stale
    end
  end

  defp evidence_until(state, step, now) do
    own = step["progress_deadline_at"]

    children =
      Enum.filter(
        Map.values(state["steps"]),
        &(&1["parent_step_id"] == step["id"] and &1["status"] == "running")
      )

    # An enclosing controller can wait while its actual child workers advance.
    candidates =
      [own | Enum.map(children, &evidence_until(state, &1, now))] |> Enum.filter(&is_binary/1)

    Enum.max_by(candidates, &millis/1, fn -> nil end)
  end

  defp extend(step, deadline) do
    step = Map.put(step, "deadline_at", deadline)

    step =
      if step["heartbeat_uses_execution_budget"],
        do: Map.put(step, "heartbeat_deadline_at", deadline),
        else: step

    step =
      if is_binary(step["progress_deadline_at"]) and
           millis(step["progress_deadline_at"]) < millis(deadline),
         do: Map.put(step, "progress_deadline_at", deadline),
         else: step

    case step["current_attempt"] do
      attempt when is_map(attempt) ->
        Map.put(step, "current_attempt", Map.put(attempt, "deadline_at", deadline))

      _ ->
        step
    end
  end

  defp after_ms(now, duration),
    do: DateTime.from_unix!(millis(now) + duration, :millisecond) |> DateTime.to_iso8601()

  defp millis(now) do
    {:ok, time, _} = DateTime.from_iso8601(now)
    DateTime.to_unix(time, :millisecond)
  end
end
