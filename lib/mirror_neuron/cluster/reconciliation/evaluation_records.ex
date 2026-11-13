defmodule MirrorNeuron.Cluster.Reconciler.EvaluationRecords do
  @moduledoc "Recovery evaluation persistence, identity and bounded transition history."

  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Runtime

  @active_eval_statuses ["pending", "running", "blocked"]

  def new_recovery_eval(job, trigger, failed_node, affected_agents, reason) do
    now = Runtime.timestamp()
    job_id = job["job_id"]

    %{
      "eval_id" => "rec-#{job_id}-#{System.unique_integer([:positive, :monotonic])}",
      "job_id" => job_id,
      "trigger" => trigger,
      "status" => "pending",
      "reason" => reason,
      "failed_node" => failed_node,
      "affected_agents" => affected_agents,
      "attempt" => 0,
      "created_at" => now,
      "updated_at" => now,
      "history" => []
    }
  end

  def find_active_eval(job_id, trigger, failed_node, opts) do
    with {:ok, evals} <- list_recovery_evals(opts, @active_eval_statuses) do
      Enum.find(evals, fn eval ->
        Map.get(eval, "job_id") == job_id and
          Map.get(eval, "trigger") == to_string(trigger) and
          Map.get(eval, "failed_node") == failed_node and
          Map.get(eval, "status") in ["pending", "running", "blocked"]
      end)
    else
      _ -> nil
    end
  end

  def list_recovery_evals(opts, statuses) do
    Options.redis_store(opts).list_recovery_evals(statuses)
  end

  def persist_recovery_eval(%{"eval_id" => eval_id} = eval, opts) do
    Options.redis_store(opts).persist_recovery_eval(eval_id, eval)
  end

  def update_recovery_eval(eval_id, updates, opts) do
    Options.redis_store(opts).update_recovery_eval(eval_id, updates)
  end

  def fetch_eval_job(eval, opts) do
    job_id = Map.get(eval, "job_id")
    Options.redis_store(opts).fetch_job(job_id)
  end

  def eval_job(eval), do: %{"job_id" => Map.get(eval, "job_id")}

  def append_eval_history(eval, status, reason) do
    entry = %{
      "status" => status,
      "reason" => reason,
      "timestamp" => Runtime.timestamp()
    }

    eval
    |> Map.get("history", [])
    |> List.wrap()
    |> Kernel.++([entry])
    |> Enum.take(-20)
  end
end
