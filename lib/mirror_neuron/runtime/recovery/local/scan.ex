defmodule MirrorNeuron.Runtime.LocalRecovery.Scan do
  @moduledoc "Selects recoverable jobs using compact summaries before loading full state."

  require Logger

  alias MirrorNeuron.Runtime.LocalRecovery.Eligibility
  alias MirrorNeuron.Runtime.LocalRecovery.Recovery
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.LocalRecovery.Status

  def recover_unfinished_jobs(opts \\ []) do
    if Keyword.get(opts, :repair_indexes?, true) do
      maybe_repair_recovery_indexes()
    end

    with {:ok, jobs} <- RedisStore.list_job_summaries() do
      jobs
      |> Enum.filter(&Eligibility.recoverable_job_status?/1)
      |> Enum.reduce(%{checked: 0, recovered: 0, paused: 0, skipped: 0, failed: 0, jobs: []}, fn
        job, acc ->
          result =
            cond do
              Eligibility.paused_for_review?(job) and not Keyword.get(opts, :manual_resume, false) ->
                Status.deregister_job_services(job["job_id"])
                %{job_id: job["job_id"], action: :skipped, reason: "job is paused for review"}

              Eligibility.job_runner_alive?(job["job_id"]) ->
                %{job_id: job["job_id"], action: :already_running, reason: "job runner is live"}

              true ->
                case fetch_and_recover_job(job, opts) do
                  {:ok, value} -> value
                  {:error, reason} -> %{job_id: job["job_id"], action: :failed, reason: reason}
                end
            end

          acc
          |> bump(result.action)
          |> Map.update!(:checked, &(&1 + 1))
          |> Map.update!(:jobs, &[result | &1])
      end)
      |> Map.update!(:jobs, &Enum.reverse/1)
      |> then(&{:ok, &1})
    end
  end

  defp fetch_and_recover_job(%{"job_id" => job_id}, opts) when is_binary(job_id) do
    with {:ok, job} <- RedisStore.fetch_job(job_id) do
      Recovery.recover_job_map(job, opts)
    end
  end

  defp fetch_and_recover_job(job, opts), do: Recovery.recover_job_map(job, opts)

  defp maybe_repair_recovery_indexes do
    case RedisStore.repair_recovery_indexes() do
      {:ok, result} ->
        if recovery_index_repairs(result) > 0 do
          Logger.info("repaired MirrorNeuron recovery indexes: #{inspect(result)}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("failed to repair MirrorNeuron recovery indexes: #{inspect(reason)}")
        :ok
    end
  end

  defp recovery_index_repairs(result) do
    Map.get(result, :repaired_jobs, 0) +
      Map.get(result, :repaired_agents, 0) +
      Map.get(result, :removed_stale_jobs, 0) +
      Map.get(result, :removed_stale_agents, 0) +
      Map.get(result, :repaired_recovery_evals, 0) +
      Map.get(result, :removed_stale_recovery_evals, 0)
  end

  def recover_job(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, job} <- RedisStore.fetch_job(job_id) do
      Recovery.recover_job_map(job, opts)
    end
  end

  defp bump(acc, :started), do: Map.update!(acc, :recovered, &(&1 + 1))

  defp bump(acc, :paused_for_review), do: Map.update!(acc, :paused, &(&1 + 1))

  defp bump(acc, :failed), do: Map.update!(acc, :failed, &(&1 + 1))

  defp bump(acc, _action), do: Map.update!(acc, :skipped, &(&1 + 1))
end
