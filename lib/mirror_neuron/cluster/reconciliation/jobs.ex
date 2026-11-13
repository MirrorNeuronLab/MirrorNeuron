defmodule MirrorNeuron.Cluster.Reconciler.Jobs do
  @moduledoc "Compact job selection, full-state loading and recovery policy classification."

  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Scheduler

  def paused_for_review?(job) do
    Map.get(job, "recovery_status") == "paused_for_review" or
      get_in(job, ["recovery", "status"]) == "paused_for_review" or
      Map.get(job, "recovery_requires_review") == true
  end

  def list_reconciliation_jobs(opts) do
    store = Options.redis_store(opts)

    cond do
      function_exported?(store, :list_job_summaries, 0) ->
        store.list_job_summaries()

      function_exported?(store, :list_jobs, 0) ->
        store.list_jobs()

      true ->
        {:ok, []}
    end
  end

  def fetch_reconciliation_job(job, opts) do
    store = Options.redis_store(opts)
    job_id = Map.get(job, "job_id")

    cond do
      full_job_record?(job) ->
        {:ok, job}

      is_binary(job_id) and function_exported?(store, :fetch_job, 1) ->
        store.fetch_job(job_id)

      true ->
        {:ok, job}
    end
  end

  defp full_job_record?(job) when is_map(job) do
    Map.has_key?(job, "manifest") or Map.has_key?(job, :manifest)
  end

  def filter_only_job_ids(jobs, nil), do: jobs

  def filter_only_job_ids(jobs, job_ids) do
    allowed =
      job_ids
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.filter(jobs, &(Map.get(&1, "job_id") in allowed))
  end

  def affected_by_node?(job, node) do
    lease_owner(job) == node or
      scheduler_affected_by_node?(Map.get(job, "scheduler", %{}), node)
  end

  defp scheduler_affected_by_node?(%{"placements" => _placements} = scheduler, node),
    do: Scheduler.affected_agent_ids(scheduler, node) != []

  defp scheduler_affected_by_node?(%{"nodes" => nodes}, node) when is_list(nodes),
    do: node in nodes

  defp scheduler_affected_by_node?(_scheduler, _node), do: false

  def safe_to_sweep?(job) do
    case DateTime.from_iso8601(job["updated_at"] || job["submitted_at"] || "") do
      {:ok, dt, _offset} ->
        DateTime.diff(DateTime.utc_now(), dt, :millisecond) > 15_000

      _ ->
        true
    end
  end

  def job_defaults(job, now) do
    %{
      "graph_id" => job["graph_id"] || "unknown",
      "job_name" => job["job_name"] || job["graph_id"] || "unknown",
      "root_agent_ids" => job["root_agent_ids"] || [],
      "placement_policy" => job["placement_policy"] || "local",
      "requested_recovery_policy" => job["requested_recovery_policy"] || "auto",
      "recovery_policy" => job["recovery_policy"] || "local_restart",
      "reliability" => job["reliability"] || %{},
      "restart_policy" => job["restart_policy"],
      "reschedule_policy" => job["reschedule_policy"],
      "policy_state" => job["policy_state"] || %{"agents" => %{}},
      "manifest" => job["manifest"],
      "manifest_ref" => job["manifest_ref"] || %{},
      "submitted_at" => job["submitted_at"] || now
    }
  end

  def cluster_recoverable?(job) do
    Map.get(job, "recovery_policy", "local_restart") == "cluster_recover"
  end

  def node_scoped_job?(job), do: job_type(job) in ["system", "sysbatch"]

  def job_type(job) do
    job["job_type"] || get_in(job, ["scheduler", "job_type"]) || "batch"
  end

  def lease_owner(job), do: job["lease_owner"] || get_in(job, ["lease", "owner_id"])
end
