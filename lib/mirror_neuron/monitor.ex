defmodule MirrorNeuron.Monitor do
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  @default_live_window_ms 300_000
  @summary_event_window 25
  @terminal_statuses ["completed", "failed", "cancelled"]
  @compact_string_bytes 8_192
  @compact_list_items 50
  @compact_job_drop_fields ["manifest", "result"]
  @compact_event_drop_fields [
    "input",
    "last_message",
    "messages",
    "output",
    "outputs",
    "result",
    "workflow_state"
  ]
  @compact_step_drop_fields ["last_message", "output"]
  @max_compact_job_bytes 1_000_000

  def list_jobs(opts \\ []) do
    with {:ok, jobs} <- list_job_records(opts) do
      {:ok, summarize_jobs(jobs, opts)}
    end
  end

  defp list_job_records(opts) do
    if Keyword.get(opts, :summary) == :basic do
      RedisStore.list_job_summaries()
    else
      RedisStore.list_jobs()
    end
  end

  defp basic_job_summary(job) do
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
      "scheduler" => scheduler_summary(job),
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
        recent_timestamp?(Map.get(job, "updated_at"), @default_live_window_ms)
    end
  end

  def job_details(job_id, opts \\ []) do
    event_limit = Keyword.get(opts, :event_limit, 25)
    event_start = if is_integer(event_limit) and event_limit > 0, do: -event_limit, else: 0

    job_fetch =
      if Keyword.get(opts, :compact, false),
        do: &RedisStore.fetch_job_summary/1,
        else: &RedisStore.fetch_job/1

    event_fetch =
      if Keyword.get(opts, :compact, false),
        do: fn -> {:ok, []} end,
        else: fn -> RedisStore.read_events(job_id, event_start, -1) end

    agent_fetch =
      if Keyword.get(opts, :compact, false),
        do: &RedisStore.list_agent_summaries/1,
        else: &RedisStore.list_agents/1

    with {:ok, job} <- job_fetch.(job_id),
         {:ok, agents} <- agent_fetch.(job_id),
         {:ok, events} <- event_fetch.() do
      agent_summaries = Enum.map(agents, &summarize_agent/1)
      sandboxes = sandbox_summaries(events, agent_summaries)

      summary =
        summarize_job(job, %{
          "agents" => agent_summaries,
          "recent_events" => events,
          "sandboxes" => sandboxes
        })

      {:ok,
       %{
         "job" => public_job(job, opts),
         "summary" => summary,
         "agents" => Enum.sort_by(agent_summaries, &{&1["assigned_node"], &1["agent_id"]}),
         "recent_events" => recent_events(events, event_limit, opts),
         "sandboxes" => sandboxes
       }}
    end
  end

  def bound_job_details(details, max_bytes \\ @max_compact_job_bytes)

  def bound_job_details(details, max_bytes) when is_map(details) and is_integer(max_bytes) do
    if encoded_size(details) <= max_bytes do
      details
    else
      reduced =
        details
        |> Map.put("recent_events", [])
        |> Map.update("summary", %{}, fn summary ->
          if is_map(summary), do: Map.put(summary, "detail_truncated", true), else: summary
        end)
        |> Map.update("job", %{}, &minimal_job/1)

      if encoded_size(reduced) <= max_bytes do
        reduced
      else
        hard_bound_job_details(reduced)
      end
    end
  end

  def bound_job_details(details, _max_bytes), do: details

  defp minimal_job(job) when is_map(job) do
    job
    |> Map.drop(["result"])
    |> Map.update("workflow_state", nil, &minimal_workflow_state/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp minimal_job(job), do: job

  defp minimal_workflow_state(%{"steps" => steps} = state) when is_map(steps) do
    minimal_steps =
      Map.new(steps, fn {step_id, step} ->
        value =
          if is_map(step) do
            Map.take(step, [
              "id",
              "status",
              "attempt_count",
              "started_at",
              "ended_at",
              "last_event_at",
              "terminal_outcome",
              "terminal_reason",
              "output_ref"
            ])
          else
            %{"status" => "unknown"}
          end

        {step_id, value}
      end)

    state
    |> Map.take(["schema_version", "job_id", "run_id", "status", "created_at", "updated_at"])
    |> Map.put("steps", minimal_steps)
  end

  defp minimal_workflow_state(_state), do: nil

  defp hard_bound_job_details(details) do
    job = Map.get(details, "job", %{})
    workflow_state = Map.get(job, "workflow_state", %{})
    step_count = workflow_state |> Map.get("steps", %{}) |> map_size_or_zero()

    %{
      "job" =>
        job
        |> Map.drop(["workflow_state"])
        |> Map.take([
          "job_id",
          "graph_id",
          "job_name",
          "status",
          "job_type",
          "submitted_at",
          "updated_at",
          "manifest_ref",
          "result_ref",
          "workflow_state_ref",
          "failure"
        ])
        |> Map.put("workflow_step_count", step_count),
      "summary" =>
        details
        |> Map.get("summary", %{})
        |> Map.take([
          "job_id",
          "graph_id",
          "job_name",
          "status",
          "submitted_at",
          "updated_at",
          "failure"
        ])
        |> Map.put("detail_truncated", true),
      "agents" => details |> Map.get("agents", []) |> Enum.take(25) |> compact_value(),
      "recent_events" => [],
      "sandboxes" => details |> Map.get("sandboxes", []) |> Enum.take(25) |> compact_value()
    }
  end

  defp map_size_or_zero(value) when is_map(value), do: map_size(value)
  defp map_size_or_zero(_value), do: 0

  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()

  defp public_job(job, opts) do
    job = Map.drop(job, ["manifest"])

    if Keyword.get(opts, :compact, false) do
      compact_job(job)
    else
      job
    end
  end

  defp compact_job(job) do
    job
    |> Map.drop(@compact_job_drop_fields)
    |> Map.update("workflow_state", nil, &compact_workflow_state/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> compact_value()
  end

  defp compact_workflow_state(%{"steps" => steps} = state) when is_map(steps) do
    compact_steps =
      Map.new(steps, fn {step_id, step} ->
        compact_step =
          if is_map(step) do
            step
            |> Map.drop(@compact_step_drop_fields)
            |> maybe_put_staged_ref("output_ref", Map.get(step, "output"))
          else
            step
          end

        {step_id, compact_step}
      end)

    state
    |> Map.drop(["messages"])
    |> Map.put("steps", compact_steps)
  end

  defp compact_workflow_state(_state), do: nil

  def cluster_overview(opts \\ []) do
    opts = Keyword.put_new(opts, :summary, :basic)

    with {:ok, raw_jobs} <- list_job_records(opts) do
      jobs = summarize_jobs(raw_jobs, opts)

      metrics =
        if Keyword.get(opts, :metrics, false) do
          case detailed_metrics(raw_jobs) do
            {:ok, values} -> values
            {:error, _reason} -> %{}
          end
        else
          summary_metrics(jobs)
        end

      {:ok,
       %{
         "nodes" => MirrorNeuron.inspect_nodes(),
         "jobs" => jobs,
         "metrics" => metrics
       }}
    end
  end

  defp summary_metrics(jobs) do
    %{
      "jobs" => %{
        "total" => length(jobs),
        "by_status" => jobs |> Enum.map(&Map.get(&1, "status", "unknown")) |> Enum.frequencies()
      },
      "nodes" => %{
        "total" => length(MirrorNeuron.inspect_nodes())
      },
      "runtime" => %{
        "generated_at" => MirrorNeuron.Runtime.timestamp(),
        "redis_namespace" => MirrorNeuron.Config.string("MN_REDIS_NAMESPACE", :redis_namespace),
        "source" => "summary"
      }
    }
  end

  def clear_jobs() do
    with {:ok, all_jobs} <- list_jobs(include_terminal: true, summary: :basic) do
      to_delete =
        Enum.reject(all_jobs, fn job ->
          job["status"] in ["running", "pending", "scheduled", "validated", "paused"]
        end)

      deleted_count =
        Enum.count(to_delete, fn job ->
          match?({:ok, _result}, Runtime.clear_job_with_result(job["job_id"]))
        end)

      {:ok, deleted_count}
    end
  end

  def metrics do
    with {:ok, jobs} <- RedisStore.list_job_summaries() do
      {:ok, jobs |> Enum.map(&basic_job_summary/1) |> summary_metrics()}
    end
  end

  def dead_letters(job_id) do
    with {:ok, events} <- RedisStore.read_events(job_id) do
      {:ok, Enum.filter(events, &(&1["type"] == "dead_letter"))}
    end
  end

  def replay_dead_letter(job_id, index) when is_integer(index) and index >= 0 do
    with {:ok, dead_letters} <- dead_letters(job_id),
         {:ok, event} <- Enum.fetch(dead_letters, index),
         agent_id when is_binary(agent_id) <- Map.get(event, "agent_id"),
         message when is_map(message) <- Map.get(event, "message"),
         {:ok, "delivered"} <- MirrorNeuron.send_message(job_id, agent_id, message) do
      {:ok, %{"replayed" => true, "job_id" => job_id, "agent_id" => agent_id, "index" => index}}
    else
      :error -> {:error, "dead letter index #{index} was not found"}
      nil -> {:error, "dead letter is missing agent_id or message"}
      {:error, reason} -> {:error, reason}
      other -> {:error, "failed to replay dead letter: #{inspect(other)}"}
    end
  end

  defp summarize_jobs(jobs, opts) do
    limit = Keyword.get(opts, :limit)
    include_terminal = Keyword.get(opts, :include_terminal, true)
    live_only = Keyword.get(opts, :live_only, false)
    summary = Keyword.get(opts, :summary, :full)

    if summary == :basic do
      jobs
      |> maybe_filter_terminal(include_terminal)
      |> Enum.sort_by(&sort_key/1, :desc)
      |> maybe_limit(limit)
      |> Enum.map(&basic_job_summary/1)
      |> maybe_filter_live(live_only)
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

  defp detailed_metrics(jobs) do
    with {:ok, details} <- metric_details(jobs) do
      {:ok,
       %{
         "jobs" => job_metrics(details),
         "agents" => agent_metrics(details),
         "events" => event_metrics(details),
         "runtime" => %{
           "generated_at" => MirrorNeuron.Runtime.timestamp(),
           "redis_namespace" => MirrorNeuron.Config.string("MN_REDIS_NAMESPACE", :redis_namespace)
         }
       }}
    end
  end

  defp metric_details(jobs) do
    Enum.reduce_while(jobs, {:ok, []}, fn job, {:ok, acc} ->
      job_id = Map.get(job, "job_id")

      with {:ok, agents} <- RedisStore.list_agents(job_id),
           {:ok, events} <- RedisStore.read_events(job_id, -100, -1) do
        {:cont, {:ok, [{job, agents, events} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, details} -> {:ok, Enum.reverse(details)}
      error -> error
    end
  end

  defp summarize_job(job, details \\ nil) do
    details =
      case details do
        nil ->
          case job_details_without_job(Map.get(job, "job_id")) do
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
      "scheduler" => scheduler_summary(job),
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

  defp job_details_without_job(nil), do: {:error, "missing job id"}

  defp job_details_without_job(job_id) do
    with {:ok, agents} <- RedisStore.list_agents(job_id),
         {:ok, events} <- RedisStore.read_events(job_id, -@summary_event_window, -1) do
      agent_summaries = Enum.map(agents, &summarize_agent/1)

      {:ok,
       %{
         "agents" => agent_summaries,
         "recent_events" => events,
         "sandboxes" => sandbox_summaries(events, agent_summaries)
       }}
    end
  end

  defp recovery_summary(job) do
    Map.get(job, "recovery") ||
      %{
        "status" => Map.get(job, "recovery_status"),
        "reason" => Map.get(job, "recovery_reason"),
        "requires_review" => Map.get(job, "recovery_requires_review", false),
        "can_resume" => Map.get(job, "status") == "paused",
        "updated_at" => Map.get(job, "updated_at")
      }
  end

  defp scheduler_summary(%{"scheduler" => scheduler}) when is_map(scheduler) do
    %{
      "status" => Map.get(scheduler, "status"),
      "job_type" => Map.get(scheduler, "job_type"),
      "strategy" => Map.get(scheduler, "strategy"),
      "mode" => Map.get(scheduler, "mode"),
      "placement_count" => Map.get(scheduler, "placement_count", 0),
      "nodes" =>
        scheduler
        |> Map.get("placements", [])
        |> Enum.map(&Map.get(&1, "node"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp scheduler_summary(_job), do: nil

  defp recent_events(events, limit, opts) when is_integer(limit) and limit > 0 do
    events
    |> Enum.reverse()
    |> Enum.take(limit)
    |> maybe_compact_values(opts)
  end

  defp recent_events(events, _limit, opts),
    do: events |> Enum.reverse() |> maybe_compact_values(opts)

  defp maybe_compact_values(values, opts) do
    if Keyword.get(opts, :compact, false) do
      Enum.map(values, &compact_event/1)
    else
      values
    end
  end

  defp compact_event(event) when is_map(event) do
    event
    |> Map.drop(@compact_event_drop_fields)
    |> Map.update("payload", nil, &compact_event_payload/1)
    |> maybe_put_staged_ref("payload_ref", event_payload_candidate(event))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> compact_value()
  end

  defp compact_event(event), do: compact_value(event)

  defp compact_event_payload(payload) when is_map(payload) do
    payload
    |> Map.drop(@compact_event_drop_fields)
    |> Map.update("_mn_step", nil, fn
      metadata when is_map(metadata) -> Map.drop(metadata, ["run_inputs", "step_input"])
      _ -> nil
    end)
    |> maybe_put_staged_ref("payload_ref", event_payload_candidate(payload))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_event_payload(payload), do: compact_value(payload)

  defp event_payload_candidate(value) when is_map(value) do
    Map.get(value, "payload_ref") ||
      Map.get(value, "result_ref") ||
      Map.get(value, "workflow_state_ref") ||
      get_in(value, ["outputs", "_mn_staged_artifact"]) ||
      get_in(value, ["result", "_mn_staged_artifact"])
  end

  defp maybe_put_staged_ref(map, key, reference) when is_map(reference) do
    if Map.get(reference, "version") == "mn.staged_artifact/v1" do
      Map.put_new(map, key, reference)
    else
      map
    end
  end

  defp maybe_put_staged_ref(map, _key, _reference), do: map

  defp compact_value(value) when is_binary(value) do
    if byte_size(value) > @compact_string_bytes do
      binary_part(value, 0, @compact_string_bytes) <>
        "\n[truncated #{byte_size(value) - @compact_string_bytes} bytes]"
    else
      value
    end
  end

  defp compact_value(value) when is_list(value) do
    compacted =
      value
      |> Enum.take(@compact_list_items)
      |> Enum.map(&compact_value/1)

    if length(value) > @compact_list_items do
      compacted ++ [%{"truncated_items" => length(value) - @compact_list_items}]
    else
      compacted
    end
  end

  defp compact_value(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, child} -> {key, compact_value(child)} end)
  end

  defp compact_value(value), do: value

  defp summarize_agent(agent) do
    current_state = Map.get(agent, "current_state", %{})
    agent_type = Map.get(agent, "agent_type")
    legacy_result = get_in(current_state, ["last_result"]) || %{}
    lease = Map.get(agent, "lease") || Map.get(legacy_result, "lease") || %{}
    sandbox = Map.get(agent, "sandbox") || %{}
    last_error = Map.get(agent, "last_error") || Map.get(current_state, "last_error")
    processed_messages = Map.get(agent, "processed_messages", 0)
    mailbox_depth = Map.get(agent, "mailbox_depth", 0)
    paused? = get_in(agent, ["metadata", "paused"]) || false
    sandbox_name = Map.get(sandbox, "name") || Map.get(legacy_result, "sandbox_name")
    sandbox_status = Map.get(sandbox, "status")

    %{
      "agent_id" => Map.get(agent, "agent_id") || Map.get(agent, "node_id"),
      "agent_type" => agent_type,
      "assigned_node" => Map.get(agent, "assigned_node"),
      "processed_messages" => processed_messages,
      "mailbox_depth" => mailbox_depth,
      "paused?" => paused?,
      "last_heartbeat_at" => Map.get(agent, "last_heartbeat_at"),
      "live?" => agent_live?(agent),
      "status" => agent_status(agent_type, paused?, sandbox_status, last_error, mailbox_depth),
      "running?" => running_agent?(agent_type, sandbox_status, last_error),
      "last_error" => last_error,
      "backpressure" => get_in(agent, ["metadata", "backpressure"]) || %{},
      "sandbox_name" => sandbox_name,
      "lease" => %{
        "lease_id" => Map.get(lease, "lease_id"),
        "pool" => Map.get(lease, "pool"),
        "slots" => Map.get(lease, "slots")
      }
    }
  end

  defp job_metrics(details) do
    by_status =
      details
      |> Enum.map(fn {job, _agents, _events} -> Map.get(job, "status", "unknown") end)
      |> Enum.frequencies()

    %{
      "total" => length(details),
      "by_status" => by_status
    }
  end

  defp agent_metrics(details) do
    agents = Enum.flat_map(details, fn {_job, agents, _events} -> agents end)

    queue_depths =
      Enum.map(agents, fn agent ->
        get_in(agent, ["metadata", "backpressure", "queue_depth"]) ||
          Map.get(agent, "mailbox_depth", 0)
      end)

    processed = Enum.map(agents, &Map.get(&1, "processed_messages", 0))

    %{
      "total" => length(agents),
      "queue_depth_total" => Enum.sum(queue_depths),
      "queue_depth_max" => Enum.max(queue_depths, fn -> 0 end),
      "processed_messages_total" => Enum.sum(processed),
      "pressured" =>
        agents
        |> Enum.map(&(get_in(&1, ["metadata", "backpressure"]) || %{}))
        |> Enum.filter(&(&1["backpressure"] == true))
    }
  end

  defp event_metrics(details) do
    events = Enum.flat_map(details, fn {_job, _agents, events} -> events end)
    by_type = events |> Enum.map(&Map.get(&1, "type", "unknown")) |> Enum.frequencies()

    %{
      "recent_window" => length(events),
      "by_type" => by_type,
      "dead_letters" => Map.get(by_type, "dead_letter", 0),
      "retry_later" => Map.get(by_type, "external_input_rejected", 0),
      "backpressure_signals" =>
        Map.get(by_type, "backpressure_state", 0) + Map.get(by_type, "backpressure_signal", 0),
      "sandbox_completed" => Map.get(by_type, "sandbox_job_completed", 0),
      "lease_wait_events" => Map.get(by_type, "executor_lease_acquired", 0),
      "redis_errors" => Map.get(by_type, "redis_error", 0)
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

  defp running_agent?("executor", status, nil),
    do: status in [nil, "pending", "starting", "running"]

  defp running_agent?(_agent_type, _sandbox_status, _last_error), do: false

  defp agent_status(_agent_type, true, _sandbox_status, _last_error, _mailbox_depth), do: "paused"

  defp agent_status("executor", false, _sandbox_status, last_error, _mailbox_depth)
       when is_binary(last_error) and last_error != "",
       do: "error"

  defp agent_status("executor", false, sandbox_status, _last_error, mailbox_depth) do
    cond do
      mailbox_depth > 0 -> "queued"
      sandbox_status in ["completed", "failed", "cancelled"] -> sandbox_status
      true -> "running"
    end
  end

  defp agent_status(_agent_type, false, _sandbox_status, _last_error, mailbox_depth) do
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
