defmodule MirrorNeuron.Runtime.LocalRecovery.Eligibility do
  @moduledoc "Classifies recoverable lifecycle states and verifies existing owners."

  alias MirrorNeuron.Persistence.RedisStore

  @active_statuses ["pending", "running", "paused"]

  def paused_for_review?(job) do
    Map.get(job, "recovery_status") == "paused_for_review" or
      get_in(job, ["recovery", "status"]) == "paused_for_review" or
      Map.get(job, "recovery_requires_review") == true
  end

  def recoverable_job_status?(%{"status" => status} = job) do
    status in @active_statuses or recoverable_runner_interruption?(job) or
      runner_interruption_recovery_hint?(job)
  end

  def recoverable_job_status?(_job), do: false

  defp runner_interruption_recovery_hint?(%{
         "status" => "failed",
         "recovery_hint" => "runner_interruption"
       }),
       do: true

  defp runner_interruption_recovery_hint?(_job), do: false

  defp recoverable_runner_interruption?(%{
         "status" => "failed",
         "result" => %{
           "agent_id" => "job_runner",
           "error" => "job coordinator exited before terminal state"
         }
       }),
       do: true

  defp recoverable_runner_interruption?(_job), do: false

  def auto_resume_mark_options(job) do
    if recoverable_runner_interruption?(job) do
      [requires_review?: false, status: "running", clear_result?: true]
    else
      [requires_review?: false]
    end
  end

  def cluster_recoverable_policy?(job) do
    Map.get(job, "recovery_policy", "local_restart") == "cluster_recover"
  end

  def active_lease?(job_id) do
    case RedisStore.get_lease("job:#{job_id}") do
      {:ok, nil} -> false
      {:ok, _lease} -> true
      {:error, _reason} -> true
    end
  end

  def job_runner_alive?(job_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) do
      [{pid, _meta}] -> pid_alive?(pid)
      _ -> false
    end
  end

  defp pid_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  defp pid_alive?(pid) when is_pid(pid) do
    case :rpc.call(node(pid), Process, :alive?, [pid], 5_000) do
      true -> true
      _ -> false
    end
  end

  defp pid_alive?(_pid), do: false
end
