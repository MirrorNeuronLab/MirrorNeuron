defmodule MirrorNeuron.Monitor.Metrics do
  @moduledoc "Aggregates cluster, job, agent and recent-event counters."

  alias MirrorNeuron.Monitor.Jobs
  alias MirrorNeuron.Monitor.Queries
  alias MirrorNeuron.Persistence.RedisStore

  def cluster_overview(opts \\ []) do
    opts = Keyword.put_new(opts, :summary, :basic)

    with {:ok, raw_jobs} <- Queries.list_job_records(opts) do
      jobs = Jobs.summarize_jobs(raw_jobs, opts)

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

  def metrics do
    with {:ok, jobs} <- RedisStore.list_job_summaries() do
      {:ok, jobs |> Enum.map(&Jobs.basic_job_summary/1) |> summary_metrics()}
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
end
