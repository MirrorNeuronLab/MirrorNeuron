defmodule MirrorNeuron.Runtime.WorkflowRetry do
  @moduledoc "Pure restoration of logical workflow boundaries, never process snapshots."
  @successful ~w(completed partial skipped)

  def restore(%{"enabled" => true, "schema_version" => 3, "steps" => steps} = ledger, now)
      when is_map(steps) do
    if valid?(ledger) do
      children = Map.get(ledger, "child_workflows", %{})

      steps =
        Map.new(steps, fn {id, step} ->
          cond do
            preserved_step?(step) -> {id, step}
            Map.has_key?(children, id) -> {id, reset(step, "waiting", now)}
            true -> {id, reset(step, "pending", now)}
          end
        end)

      if Enum.any?(children, fn {_id, child} -> child["phase"] == "failed" end) do
        {:error,
         "A child workflow rejected its plan. Its boundary cannot be replayed safely. Start a new run."}
      else
        {:ok,
         ledger
         |> Map.merge(%{
           "status" => "running",
           "paused_at" => nil,
           "updated_at" => now,
           "steps" => steps,
           "child_workflows" => children,
           "messages" => %{}
         })}
      end
    else
      {:error, "Checkpoint step identities or progress are invalid. Start a new run."}
    end
  end

  def restore(_, _), do: {:error, "Checkpoint workflow version is unsupported."}

  def preserved(ledger), do: select(ledger, &preserved_step?/1)
  def unfinished(ledger), do: select(ledger, &(not preserved_step?(&1)))

  defp valid?(ledger) do
    order = ledger["step_order"]

    is_list(order) and order != [] and Enum.uniq(order) == order and
      MapSet.new(order) == MapSet.new(Map.keys(ledger["steps"])) and
      Enum.all?(order, fn id ->
        step = ledger["steps"][id]

        is_map(step) and step["id"] == id and
          is_integer(step["attempt_count"] || 0) and (step["attempt_count"] || 0) >= 0 and
          is_list(step["needs"] || []) and
          step["status"] in ~w(pending ready blocked queued running retry_wait waiting failed timed_out cancelled completed partial skipped)
      end) and is_map(ledger["child_workflows"] || %{})
  end

  defp preserved_step?(step) do
    step["status"] in @successful and
      get_in(step, ["output", "reason"]) != "trigger rule cannot be satisfied"
  end

  defp select(ledger, predicate) do
    Enum.filter(Map.get(ledger, "step_order", []), fn id -> predicate.(ledger["steps"][id]) end)
  end

  defp reset(step, status, now) do
    key =
      get_in(step, ["current_attempt", "idempotency_key"]) ||
        get_in(step, ["last_message", "headers", "mn.workflow.idempotency_key"]) ||
        step["retry_idempotency_key"]

    step
    |> Map.merge(%{
      "status" => status,
      "current_attempt" => nil,
      "deadline_at" => nil,
      "heartbeat_deadline_at" => nil,
      "retry_at" => nil,
      "ended_at" => nil,
      "terminal_reason" => nil,
      "terminal_error" => nil,
      "last_error" => nil,
      "last_event_at" => now,
      "retry_idempotency_key" => key,
      "checkpoint_retry_delivery" => true
    })
  end
end
