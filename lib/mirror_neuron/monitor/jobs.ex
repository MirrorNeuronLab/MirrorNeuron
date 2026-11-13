defmodule MirrorNeuron.Monitor.Jobs do
  @moduledoc "Builds and filters job summaries from durable runtime observations."

  alias MirrorNeuron.Monitor.Agents
  alias MirrorNeuron.Scheduler.Monitoring
  alias MirrorNeuron.Monitor.Queries

  @default_live_window_ms 300_000
  @terminal_statuses ["completed", "failed", "cancelled"]

  def basic_job_summary(job) do
    %{
      "job_id" => Map.get(job, "job_id"),
      "graph_id" => Map.get(job, "graph_id"),
      "job_name" => Map.get(job, "job_name"),
      "status" => Map.get(job, "status"),
      "job_type" => Map.get(job, "job_type"),
      "live?" => basic_job_live?(job),
      "submitted_at" => Map.get(job, "submitted_at"),
      "updated_at" => Map.get(job, "updated_at"),
      "placement_policy" => Map.get(job, "placement_policy"),
      "scheduler" => Monitoring.scheduler_summary(job),
      "requested_recovery_policy" => Map.get(job, "requested_recovery_policy"),
      "recovery_policy" => Map.get(job, "recovery_policy"),
      "reliability" => Map.get(job, "reliability"),
      "restart_policy" => Map.get(job, "restart_policy"),
      "reschedule_policy" => Map.get(job, "reschedule_policy"),
      "policy_state" => Map.get(job, "policy_state"),
      "recovery_status" => Map.get(job, "recovery_status"),
      "recovery_requires_review" => Map.get(job, "recovery_requires_review", false),
      "recovery_reason" => Map.get(job, "recovery_reason"),
      "executor_count" => Map.get(job, "executor_count", 0),
      "active_executors" => Map.get(job, "active_executors", 0),
      "nodes" => Map.get(job, "nodes", []),
      "sandbox_names" => Map.get(job, "sandbox_names", []),
      "last_event" => Map.get(job, "last_event"),
      "failure" => Map.get(job, "failure")
    }
  end

  defp basic_job_live?(job) do
    cond do
      Map.get(job, "status") in @terminal_statuses ->
        false

      true ->
        Agents.recent_timestamp?(Map.get(job, "updated_at"), @default_live_window_ms)
    end
  end

  def summarize_jobs(jobs, opts) do
    limit = Keyword.get(opts, :limit)
    include_terminal = Keyword.get(opts, :include_terminal, true)
    live_only = Keyword.get(opts, :live_only, false)
    summary = Keyword.get(opts, :summary, :full)

    if summary == :basic do
      jobs
      |> maybe_filter_terminal(include_terminal)
      |> Enum.sort_by(&sort_key/1, :desc)
      |> Enum.map(&basic_job_summary/1)
      |> maybe_filter_live(live_only)
      |> maybe_limit(limit)
    else
      if live_only do
        jobs
        |> maybe_filter_terminal(include_terminal)
        |> Enum.map(&summarize_job/1)
        |> maybe_filter_live(true)
        |> Enum.sort_by(&sort_key/1, :desc)
        |> maybe_limit(limit)
      else
        jobs
        |> maybe_filter_terminal(include_terminal)
        |> Enum.sort_by(&sort_key/1, :desc)
        |> maybe_limit(limit)
        |> Enum.map(&summarize_job/1)
      end
    end
  end

  def summarize_job(job, details \\ nil) do
    details =
      case details do
        nil ->
          case Queries.job_details_without_job(Map.get(job, "job_id")) do
            {:ok, details} -> details
            {:error, _reason} -> %{"agents" => [], "recent_events" => [], "sandboxes" => []}
          end

        details ->
          details
      end

    agents = details["agents"]
    events = details["recent_events"]

    %{
      "job_id" => Map.get(job, "job_id"),
      "graph_id" => Map.get(job, "graph_id"),
      "job_name" => Map.get(job, "job_name"),
      "status" => Map.get(job, "status"),
      "job_type" => Map.get(job, "job_type"),
      "live?" => job_live?(job, agents),
      "submitted_at" => Map.get(job, "submitted_at"),
      "updated_at" => Map.get(job, "updated_at"),
      "placement_policy" => Map.get(job, "placement_policy"),
      "scheduler" => Monitoring.scheduler_summary(job),
      "requested_recovery_policy" => Map.get(job, "requested_recovery_policy"),
      "recovery_policy" => Map.get(job, "recovery_policy"),
      "reliability" => Map.get(job, "reliability"),
      "restart_policy" => Map.get(job, "restart_policy"),
      "reschedule_policy" => Map.get(job, "reschedule_policy"),
      "policy_state" => Map.get(job, "policy_state"),
      "recovery" => recovery_summary(job),
      "executor_count" => Enum.count(agents, &(&1["agent_type"] == "executor")),
      "active_executors" =>
        Enum.count(agents, &(&1["agent_type"] == "executor" and &1["running?"])),
      "nodes" =>
        agents
        |> Enum.map(& &1["assigned_node"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort(),
      "sandbox_names" =>
        details["sandboxes"] |> Enum.map(& &1["sandbox_name"]) |> Enum.uniq() |> Enum.sort(),
      "last_event" => format_last_event(events),
      "failure" => Map.get(job, "failure")
    }
  end

  defp recovery_summary(job) do
    Map.get(job, "recovery")
  end

  defp maybe_filter_terminal(jobs, true), do: jobs

  defp maybe_filter_terminal(jobs, false) do
    Enum.reject(jobs, &(Map.get(&1, "status") in @terminal_statuses))
  end

  defp maybe_filter_live(jobs, true) do
    Enum.filter(jobs, &Map.get(&1, "live?", false))
  end

  defp maybe_filter_live(jobs, false), do: jobs

  defp maybe_limit(jobs, nil), do: jobs

  defp maybe_limit(jobs, limit) when is_integer(limit) and limit > 0, do: Enum.take(jobs, limit)

  defp maybe_limit(jobs, _limit), do: jobs

  defp sort_key(job) do
    Map.get(job, "updated_at") || Map.get(job, "submitted_at") || ""
  end

  defp format_last_event([]), do: nil

  defp format_last_event(events) do
    event = List.last(events)
    agent = Map.get(event, "agent_id")
    type = Map.get(event, "type")

    if agent do
      "#{type}(#{agent})"
    else
      type
    end
  end

  defp job_live?(job, agents) do
    cond do
      Map.get(job, "status") in @terminal_statuses ->
        false

      Enum.any?(agents, &Map.get(&1, "live?", false)) ->
        true

      true ->
        Agents.recent_timestamp?(Map.get(job, "updated_at"), @default_live_window_ms)
    end
  end
end
