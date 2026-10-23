defmodule MirrorNeuron.Runtime.WorkflowActivity do
  @moduledoc false

  # A shared inactivity allowance, never a cap on the lifetime of healthy work.
  @progress_timeout_ms 300_000
  @max_wait_ms 86_400_000

  def enabled?(flow), do: get_in(flow, ["execution", "supervision"]) == "activity"

  def validation_errors(flow, nodes) do
    case get_in(flow, ["execution", "supervision"]) do
      nil ->
        []

      "activity" ->
        for node <- nodes,
            node.agent_type in ["executor", :executor],
            config = node.config || %{},
            config["runner_module"] != "MirrorNeuron.Runner.HostLocal" or
              config["beacon_enabled"] != true or config["agent_beacon_required"] != true,
            do: "activity supervision requires HostLocal workers with required live SDK beacons"

      _ ->
        ["workflow.execution.supervision must be activity when supplied"]
    end
  end

  def start(%{"supervision" => "activity"} = step, now) do
    Map.merge(step, %{
      "progress_deadline_at" => after_ms(now, @progress_timeout_ms),
      "progress_sequences" => %{},
      "waiting_id" => nil,
      "work_state" => "active"
    })
  end

  def start(step, _now), do: step

  def observe(%{"supervision" => "activity"} = step, payload, now) do
    # Runner-generated liveness and duplicate/replayed beacons cannot prove work
    # advanced. Keep counters per physical worker within this logical attempt.
    sequence = payload["progress_sequence"]
    key = payload["agent_id"]
    pid = payload["pid"]
    previous = Map.get(step["progress_sequences"] || %{}, key, %{})
    previous_sequence = if previous["pid"] == pid, do: previous["sequence"], else: -1

    if payload["source"] == "agent" and is_integer(sequence) and sequence >= 0 and
         is_integer(pid) and pid > 0 and key in step["agent_ids"] and
         sequence > previous_sequence do
      step
      |> Map.put(
        "progress_sequences",
        Map.put(step["progress_sequences"] || %{}, key, %{"pid" => pid, "sequence" => sequence})
      )
      |> waiting(payload, now)
    else
      step
    end
  end

  def observe(step, _payload, _now), do: step

  defp waiting(step, %{"wait_id" => id, "wait_timeout_ms" => timeout}, now)
       when is_binary(id) and byte_size(id) in 1..128 and is_integer(timeout) and
              timeout > 0 and timeout <= @max_wait_ms do
    # A repeated wait identity must never extend an unanswered human request.
    if step["waiting_id"] == id do
      step
    else
      Map.merge(step, %{
        "waiting_id" => id,
        "work_state" => "waiting",
        "progress_deadline_at" => after_ms(now, timeout + @progress_timeout_ms)
      })
    end
  end

  defp waiting(step, _payload, now) do
    Map.merge(step, %{
      "waiting_id" => nil,
      "work_state" => "active",
      "progress_deadline_at" => after_ms(now, @progress_timeout_ms)
    })
  end

  defp after_ms(now, ms) do
    {:ok, time, _} = DateTime.from_iso8601(now)
    time |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()
  end
end
