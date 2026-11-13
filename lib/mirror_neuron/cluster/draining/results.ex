defmodule MirrorNeuron.Cluster.NodeDrainer.Results do
  @moduledoc "Classifies drain progress and accumulates job and node outcomes."

  alias MirrorNeuron.Cluster.NodeDrainer.Jobs

  def drain_status(result) do
    counters = result["counters"]

    cond do
      Map.get(counters, "failed", 0) > 0 -> "blocked_no_placement"
      Map.get(counters, "blocked", 0) > 0 -> "blocked_no_placement"
      Map.get(counters, "paused_for_review", 0) > 0 -> "paused_for_review"
      Map.get(counters, "waiting", 0) > 0 -> "draining"
      true -> "complete"
    end
  end

  def empty_result(context) do
    %{
      "node" => context.node,
      "status" => if(context.dry_run?, do: "dry_run", else: "draining"),
      "actions" => [],
      "counters" => %{}
    }
  end

  def action(job, status, reason, affected_agents, extra \\ %{}) do
    %{
      "job_id" => job["job_id"],
      "job_type" => Jobs.job_type(job),
      "status" => status,
      "reason" => reason,
      "affected_agents" => affected_agents
    }
    |> Map.merge(extra)
  end

  def record_action(result, action) do
    Map.update!(result, "actions", &(&1 ++ [action]))
  end

  def counters(actions) do
    Enum.reduce(actions, %{"checked" => length(actions)}, fn action, acc ->
      Map.update(acc, Map.get(action, "status", "unknown"), 1, &(&1 + 1))
    end)
  end

  def empty_sweep_result do
    %{
      "checked" => 0,
      "completed" => 0,
      "blocked" => 0,
      "waiting" => 0,
      "failed" => 0,
      "nodes" => []
    }
  end

  def merge_sweep_result(acc, result) do
    status = Map.get(result, "status")

    acc
    |> Map.update!("checked", &(&1 + 1))
    |> Map.update!("nodes", &(&1 ++ [result]))
    |> bump_sweep(status)
  end

  def record_sweep_failure(acc, node, reason) do
    acc
    |> Map.update!("checked", &(&1 + 1))
    |> Map.update!("failed", &(&1 + 1))
    |> Map.update!(
      "nodes",
      &(&1 ++ [%{"node" => node, "status" => "failed", "reason" => inspect(reason)}])
    )
  end

  defp bump_sweep(acc, "complete"), do: Map.update!(acc, "completed", &(&1 + 1))

  defp bump_sweep(acc, "draining"), do: Map.update!(acc, "waiting", &(&1 + 1))

  defp bump_sweep(acc, "blocked_no_placement"), do: Map.update!(acc, "blocked", &(&1 + 1))

  defp bump_sweep(acc, "paused_for_review"), do: Map.update!(acc, "blocked", &(&1 + 1))

  defp bump_sweep(acc, _status), do: acc
end
