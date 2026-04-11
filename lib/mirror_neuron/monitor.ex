defmodule MirrorNeuron.Monitor do
  alias MirrorNeuron.Persistence.RedisStore

  @default_live_window_ms 10_000
  @terminal_statuses ["completed", "failed", "cancelled"]

  def list_jobs(opts \\ []) do
    limit = Keyword.get(opts, :limit)
    include_terminal = Keyword.get(opts, :include_terminal, true)
    live_only = Keyword.get(opts, :live_only, false)

    with {:ok, jobs} <- RedisStore.list_jobs() do
      jobs =
        jobs
        |> Enum.map(&summarize_job/1)
        |> maybe_filter_terminal(include_terminal)
        |> maybe_filter_live(live_only)
        |> Enum.sort_by(&sort_key/1, :desc)
        |> maybe_limit(limit)

      {:ok, jobs}
    end
  end

  def job_details(job_id, opts \\ []) do
    event_limit = Keyword.get(opts, :event_limit, 25)

    with {:ok, job} <- RedisStore.fetch_job(job_id),
         {:ok, agents} <- RedisStore.list_agents(job_id),
         {:ok, events} <- RedisStore.read_events(job_id) do
      summary = summarize_job(job)
      agent_summaries = Enum.map(agents, &summarize_agent/1)
      sandboxes = sandbox_summaries(events, agent_summaries)

      {:ok,
       %{
         "job" => job,
         "summary" => summary,
         "agents" => Enum.sort_by(agent_summaries, &{&1["assigned_node"], &1["agent_id"]}),
         "recent_events" => Enum.take(Enum.reverse(events), event_limit),
         "sandboxes" => sandboxes
       }}
    end
  end

  def cluster_overview(opts \\ []) do
    with {:ok, jobs} <- list_jobs(opts) do
      {:ok,
       %{
         "nodes" => MirrorNeuron.inspect_nodes(),
         "jobs" => jobs
       }}
    end
  end

  defp summarize_job(job) do
    details =
      case job_details_without_job(Map.get(job, "job_id")) do
        {:ok, details} -> details
        {:error, _reason} -> %{"agents" => [], "recent_events" => [], "sandboxes" => []}
      end

    agents = details["agents"]
    events = details["recent_events"]

    %{
      "job_id" => Map.get(job, "job_id"),
      "graph_id" => Map.get(job, "graph_id"),
      "job_name" => Map.get(job, "job_name"),
      "status" => Map.get(job, "status"),
      "live?" => job_live?(job, agents),
      "submitted_at" => Map.get(job, "submitted_at"),
      "updated_at" => Map.get(job, "updated_at"),
      "placement_policy" => Map.get(job, "placement_policy"),
      "recovery_policy" => Map.get(job, "recovery_policy"),
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
      "last_event" => format_last_event(events)
    }
  end

  defp job_details_without_job(nil), do: {:error, "missing job id"}

  defp job_details_without_job(job_id) do
    with {:ok, agents} <- RedisStore.list_agents(job_id),
         {:ok, events} <- RedisStore.read_events(job_id) do
      agent_summaries = Enum.map(agents, &summarize_agent/1)

      {:ok,
       %{
         "agents" => agent_summaries,
         "recent_events" => events,
         "sandboxes" => sandbox_summaries(events, agent_summaries)
       }}
    end
  end

  defp summarize_agent(agent) do
    current_state = Map.get(agent, "current_state", %{})
    agent_type = Map.get(agent, "agent_type")
    lease = get_in(current_state, ["last_result", "lease"]) || %{}
    last_result = get_in(current_state, ["last_result"]) || %{}
    last_error = Map.get(current_state, "last_error")
    processed_messages = Map.get(agent, "processed_messages", 0)
    mailbox_depth = Map.get(agent, "mailbox_depth", 0)
    paused? = get_in(agent, ["metadata", "paused"]) || false

    %{
      "agent_id" => Map.get(agent, "agent_id") || Map.get(agent, "node_id"),
      "agent_type" => agent_type,
      "assigned_node" => Map.get(agent, "assigned_node"),
      "processed_messages" => processed_messages,
      "mailbox_depth" => mailbox_depth,
      "paused?" => paused?,
      "last_heartbeat_at" => Map.get(agent, "last_heartbeat_at"),
      "live?" => agent_live?(agent),
      "status" => agent_status(agent_type, paused?, current_state, last_error, mailbox_depth),
      "running?" => running_agent?(agent_type, current_state, last_error),
      "last_error" => last_error,
      "sandbox_name" => Map.get(last_result, "sandbox_name"),
      "lease" => %{
        "lease_id" => Map.get(lease, "lease_id"),
        "pool" => Map.get(lease, "pool"),
        "slots" => Map.get(lease, "slots")
      }
    }
  end

  defp sandbox_summaries(events, agents) do
    sandboxes_from_events =
      events
      |> Enum.filter(&(&1["type"] in ["sandbox_job_completed", "sandbox_job_failed"]))
      |> Enum.map(fn event ->
        payload = Map.get(event, "payload", %{})

        %{
          "agent_id" => Map.get(event, "agent_id"),
          "sandbox_name" => Map.get(payload, "sandbox_name"),
          "exit_code" => Map.get(payload, "exit_code"),
          "pool" => Map.get(payload, "pool"),
          "timestamp" => Map.get(event, "timestamp")
        }
      end)

    sandboxes_from_agents =
      agents
      |> Enum.map(fn agent ->
        %{
          "agent_id" => agent["agent_id"],
          "sandbox_name" => agent["sandbox_name"],
          "exit_code" => nil,
          "pool" => get_in(agent, ["lease", "pool"]),
          "timestamp" => nil
        }
      end)

    (sandboxes_from_events ++ sandboxes_from_agents)
    |> Enum.reject(&is_nil(&1["sandbox_name"]))
    |> Enum.uniq_by(&{&1["agent_id"], &1["sandbox_name"]})
    |> Enum.sort_by(&{&1["agent_id"], &1["sandbox_name"]})
  end

  defp running_agent?("executor", current_state, nil) do
    runs = Map.get(current_state, "runs", 0)
    last_result = Map.get(current_state, "last_result")
    runs == 0 or is_nil(last_result)
  end

  defp running_agent?(_agent_type, _current_state, _last_error), do: false

  defp agent_status(_agent_type, true, _current_state, _last_error, _mailbox_depth), do: "paused"

  defp agent_status("executor", false, _current_state, last_error, _mailbox_depth)
       when is_binary(last_error) and last_error != "",
       do: "error"

  defp agent_status("executor", false, current_state, _last_error, mailbox_depth) do
    cond do
      mailbox_depth > 0 -> "queued"
      is_map(Map.get(current_state, "last_result")) -> "completed"
      true -> "running"
    end
  end

  defp agent_status(_agent_type, false, _current_state, _last_error, mailbox_depth) do
    if mailbox_depth > 0, do: "busy", else: "ready"
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
        recent_timestamp?(Map.get(job, "updated_at"), @default_live_window_ms)
    end
  end

  defp agent_live?(agent) do
    heartbeat = Map.get(agent, "last_heartbeat_at")
    interval_ms = get_in(agent, ["metadata", "heartbeat_interval_ms"]) || 2_000
    live_window_ms = max(interval_ms * 3, @default_live_window_ms)
    recent_timestamp?(heartbeat, live_window_ms)
  end

  defp recent_timestamp?(nil, _window_ms), do: false

  defp recent_timestamp?(timestamp, window_ms) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(timestamp) do
      abs(DateTime.diff(DateTime.utc_now(), dt, :millisecond)) <= window_ms
    else
      _ -> false
    end
  end
end
