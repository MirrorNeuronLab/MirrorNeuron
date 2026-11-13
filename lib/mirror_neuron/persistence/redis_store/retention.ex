defmodule MirrorNeuron.Persistence.RedisStore.Retention do
  @moduledoc "Coordinates record retention, stale index cleanup and referenced blob refresh."

  require Logger

  alias MirrorNeuron.Artifacts.BlobRef
  alias MirrorNeuron.Persistence.RedisStore.Blobs
  alias MirrorNeuron.Persistence.RedisStore.Checkpoints
  alias MirrorNeuron.Persistence.RedisStore.DeploymentIndex
  alias MirrorNeuron.Persistence.RedisStore.JobCleanup
  alias MirrorNeuron.Persistence.RedisStore.Jobs
  alias MirrorNeuron.Persistence.RedisStore.RecoveryIndex
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.ScheduleIndex
  alias MirrorNeuron.Persistence.RedisStore.ServiceIndex

  def sweep_retention(opts \\ []) do
    ttl_seconds =
      Keyword.get(opts, :terminal_job_ttl_seconds, RetentionPolicy.terminal_job_ttl_seconds())

    cleanup_job = Keyword.get(opts, :cleanup_job, fn _job_id -> :ok end)

    with {:ok, job_ids} <- Jobs.list_job_ids(),
         {:ok, eval_result} <- RecoveryIndex.sweep_recovery_eval_retention(),
         {:ok, blob_result} <- Blobs.sweep_blob_ref_index(),
         {:ok, service_result} <- ServiceIndex.sweep_service_instance_index(),
         {:ok, schedule_result} <- ScheduleIndex.sweep_schedule_index(),
         {:ok, deployment_result} <- DeploymentIndex.sweep_deployment_indexes() do
      result =
        Enum.reduce(job_ids, %{deleted_jobs: [], stale_job_ids: []}, fn job_id, acc ->
          case Jobs.fetch_job(job_id) do
            {:ok, job} ->
              refresh_job_blob_refs(job)

              if RetentionPolicy.terminal_job_expired?(job, ttl_seconds) do
                case run_retention_cleanup(cleanup_job, job_id, job) do
                  :ok ->
                    case JobCleanup.delete_job(job_id) do
                      :ok ->
                        Map.update!(acc, :deleted_jobs, &[job_id | &1])

                      {:error, reason} ->
                        Logger.warning(
                          "retention deletion deferred for #{job_id}: #{inspect(reason)}"
                        )

                        acc
                    end

                  {:error, reason} ->
                    Logger.warning("retention cleanup deferred for #{job_id}: #{inspect(reason)}")

                    acc
                end
              else
                acc
              end

            {:error, reason} ->
              if Jobs.missing_job?(job_id, reason) do
                case run_retention_cleanup(cleanup_job, job_id, nil) do
                  :ok ->
                    case JobCleanup.delete_job(job_id) do
                      :ok ->
                        Map.update!(acc, :stale_job_ids, &[job_id | &1])

                      {:error, delete_reason} ->
                        Logger.warning(
                          "stale job deletion deferred for #{job_id}: #{inspect(delete_reason)}"
                        )

                        acc
                    end

                  {:error, cleanup_reason} ->
                    Logger.warning(
                      "stale job cleanup deferred for #{job_id}: #{inspect(cleanup_reason)}"
                    )

                    acc
                end
              else
                Logger.warning(
                  "retention could not classify job #{job_id}; cleanup deferred: #{inspect(reason)}"
                )

                acc
              end
          end
        end)

      deleted_jobs = Enum.reverse(result.deleted_jobs)
      stale_job_ids = Enum.reverse(result.stale_job_ids)

      {:ok,
       %{
         deleted_count: length(deleted_jobs),
         stale_count: length(stale_job_ids),
         deleted_jobs: deleted_jobs,
         stale_job_ids: stale_job_ids,
         deleted_recovery_eval_count: Map.get(eval_result, :deleted_recovery_eval_count, 0),
         stale_recovery_eval_count: Map.get(eval_result, :stale_recovery_eval_count, 0),
         deleted_recovery_evals: Map.get(eval_result, :deleted_recovery_evals, []),
         stale_recovery_evals: Map.get(eval_result, :stale_recovery_evals, []),
         stale_blob_ref_count: Map.get(blob_result, :stale_blob_ref_count, 0),
         stale_blob_refs: Map.get(blob_result, :stale_blob_refs, []),
         stale_service_instance_count: Map.get(service_result, :stale_service_instance_count, 0),
         stale_service_instances: Map.get(service_result, :stale_service_instances, []),
         stale_schedule_count: Map.get(schedule_result, :stale_schedule_count, 0),
         stale_schedules: Map.get(schedule_result, :stale_schedules, []),
         stale_deployment_count: Map.get(deployment_result, :stale_deployment_count, 0),
         stale_deployments: Map.get(deployment_result, :stale_deployments, []),
         stale_deployment_version_count:
           Map.get(deployment_result, :stale_deployment_version_count, 0)
       }}
    end
  end

  defp run_retention_cleanup(cleanup_job, job_id, job) do
    result =
      cond do
        is_function(cleanup_job, 2) -> cleanup_job.(job_id, job)
        is_function(cleanup_job, 1) -> cleanup_job.(job_id)
      end

    case result do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_cleanup_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp refresh_job_blob_refs(job) do
    checkpoint =
      case Checkpoints.fetch_run_checkpoint(job["job_id"]) do
        {:ok, checkpoint} -> checkpoint
        _ -> %{}
      end

    [job, checkpoint]
    |> BlobRef.collect()
    |> Enum.each(fn ref ->
      case Blobs.register_blob_ref(ref) do
        {:ok, _blob} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "failed to refresh blob metadata #{ref["sha256"]} for job #{job["job_id"]}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end
end
