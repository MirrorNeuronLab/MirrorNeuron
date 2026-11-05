defmodule MirrorNeuron.Runner.CommandBudget do
  @moduledoc false
  alias MirrorNeuron.Runtime.{WorkflowActivity, WorkflowPreparation}

  def new(timeout_ms, environment, now) do
    attempt = environment["MN_WORKFLOW_ATTEMPT_ID"] || "command"

    step = %{
      "status" => "running",
      "agent_ids" => ["command"],
      "current_attempt" => %{"attempt_id" => attempt},
      "timeout_seconds" => if(timeout_ms, do: timeout_ms / 1000),
      "deadline_at" => if(timeout_ms, do: at(timeout_ms)),
      "progress_sequences" => %{}
    }

    %{started: now, step: step}
  end

  def observe(budget, type, payload, now) do
    timestamp = at(max(now - budget.started, 0))
    step = WorkflowPreparation.advance(budget.step, timestamp)

    step =
      case to_string(type) do
        "agent_beacon" ->
          if is_nil(step["deadline_at"]),
            do: step,
            else:
              WorkflowActivity.observe(step, Map.put(payload, "agent_id", "command"), timestamp)

        type when type in ["runtime_preparation_started", "runtime_preparation_finished"] ->
          WorkflowPreparation.observe(step, "command", type, payload, timestamp)

        _ ->
          step
      end

    %{budget | step: step}
  end

  def remaining(budget, now) do
    elapsed = max(now - budget.started, 0)
    timestamp = at(elapsed)
    step = WorkflowPreparation.advance(budget.step, timestamp)
    deadlines = [step["deadline_at"], step["progress_deadline_at"]] |> Enum.filter(&is_binary/1)
    deadline = Enum.max_by(deadlines, &millis/1, fn -> nil end)
    preparation = get_in(step, ["preparation", "active"]) || %{}
    # Preparation deadlines remain hard and independent of execution/progress.
    preparation_remaining =
      preparation |> Map.values() |> Enum.map(&max(&1["deadline_ms"] - elapsed, 0))

    work_remaining = if deadline, do: [max(millis(deadline) - elapsed, 0)], else: []
    remaining = Enum.min(preparation_remaining ++ work_remaining, fn -> :infinity end)
    {remaining, %{budget | step: step}}
  end

  defp at(ms), do: DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()

  defp millis(timestamp) do
    {:ok, time, _} = DateTime.from_iso8601(timestamp)
    DateTime.to_unix(time, :millisecond)
  end
end
