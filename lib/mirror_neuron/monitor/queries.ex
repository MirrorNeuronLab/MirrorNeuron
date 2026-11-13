defmodule MirrorNeuron.Monitor.Queries do
  @moduledoc "Reads compact or detailed job observations without calling workers."

  alias MirrorNeuron.Monitor.Agents
  alias MirrorNeuron.Monitor.Compaction
  alias MirrorNeuron.Monitor.Jobs
  alias MirrorNeuron.Persistence.RedisStore

  @summary_event_window 25

  def list_jobs(opts \\ []) do
    with {:ok, jobs} <- list_job_records(opts) do
      {:ok, Jobs.summarize_jobs(jobs, opts)}
    end
  end

  def list_job_records(opts) do
    if Keyword.get(opts, :summary) == :basic do
      RedisStore.list_job_summaries()
    else
      RedisStore.list_jobs()
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
      agent_summaries = Enum.map(agents, &Agents.summarize_agent/1)
      sandboxes = Agents.sandbox_summaries(events, agent_summaries)

      summary =
        Jobs.summarize_job(job, %{
          "agents" => agent_summaries,
          "recent_events" => events,
          "sandboxes" => sandboxes
        })

      {:ok,
       %{
         "job" => Compaction.public_job(job, opts),
         "summary" => summary,
         "agents" => Enum.sort_by(agent_summaries, &{&1["assigned_node"], &1["agent_id"]}),
         "recent_events" => Compaction.recent_events(events, event_limit, opts),
         "sandboxes" => sandboxes
       }}
    end
  end

  def job_details_without_job(nil), do: {:error, "missing job id"}

  def job_details_without_job(job_id) do
    with {:ok, agents} <- RedisStore.list_agents(job_id),
         {:ok, events} <- RedisStore.read_events(job_id, -@summary_event_window, -1) do
      agent_summaries = Enum.map(agents, &Agents.summarize_agent/1)

      {:ok,
       %{
         "agents" => agent_summaries,
         "recent_events" => events,
         "sandboxes" => Agents.sandbox_summaries(events, agent_summaries)
       }}
    end
  end
end
