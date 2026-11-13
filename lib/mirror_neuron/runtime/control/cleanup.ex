defmodule MirrorNeuron.Runtime.Cleanup do
  @moduledoc "Retires terminal runs and reconciles durable cancellation before deleting state."

  require Logger

  alias MirrorNeuron.Persistence.CancellationStore
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.ControlErrors
  alias MirrorNeuron.Runtime.JobCleanup
  alias MirrorNeuron.Runtime.JobControl
  alias MirrorNeuron.Runtime.NodeAdmission

  def cleanup_jobs(opts \\ []) do
    force_all = Keyword.get(opts, :all, false)

    case MirrorNeuron.Persistence.RedisStore.list_jobs() do
      {:ok, jobs} ->
        result =
          jobs
          |> Enum.filter(fn job ->
            force_all or job["status"] in ["completed", "failed", "cancelled", "cancelling"]
          end)
          |> Enum.reduce(%{deleted_jobs: [], failed_jobs: []}, fn job, acc ->
            case prepare_job_cleanup(job, force_all) do
              :ok ->
                job_id = job["job_id"]

                case clear_job_with_result(job_id) do
                  {:ok, _clear_result} ->
                    Map.update!(acc, :deleted_jobs, &[job_id | &1])

                  {:error, reason} ->
                    failure = %{
                      "job_id" => job_id,
                      "reason" => ControlErrors.error_message(reason)
                    }

                    Map.update!(acc, :failed_jobs, &[failure | &1])
                end

              {:error, reason} ->
                failure = %{
                  "job_id" => job["job_id"],
                  "reason" => ControlErrors.error_message(reason)
                }

                Map.update!(acc, :failed_jobs, &[failure | &1])
            end
          end)

        deleted_jobs = Enum.reverse(result.deleted_jobs)
        failed_jobs = Enum.reverse(result.failed_jobs)

        Enum.each(failed_jobs, fn failure ->
          Logger.warning("failed to safely clean job #{failure["job_id"]}: #{failure["reason"]}")
        end)

        {:ok, %{deleted_count: length(deleted_jobs), deleted_jobs: deleted_jobs}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def clear_job(job_id) when is_binary(job_id) do
    case clear_job_with_result(job_id) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def clear_job_with_result(job_id) when is_binary(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} ->
        clear_persisted_job(job_id, job)

      {:error, reason} ->
        publicly_cleared_result(job_id, reason)
    end
  end

  defp clear_persisted_job(job_id, %{"status" => status} = job)
       when status in ["cancelling", "cancelled"] do
    case CancellationStore.fetch(job_id) do
      {:ok, %{"status" => "acknowledged"}} ->
        clear_durable_cancellation(job_id, true)

      {:ok, %{"status" => "pending"}} ->
        clear_durable_cancellation(job_id, false)

      _ ->
        clear_terminal_job(job_id, job)
    end
  end

  defp clear_persisted_job(job_id, job), do: clear_terminal_job(job_id, job)

  defp clear_durable_cancellation(job_id, cleanup_native?) do
    with :ok <- maybe_cleanup_acknowledged_native_resources(job_id, cleanup_native?),
         :ok <- if(cleanup_native?, do: NodeAdmission.retire(job_id), else: :ok),
         {:ok, _cancellation} <- CancellationStore.mark_public_cleared(job_id),
         :ok <- RedisStore.delete_job(job_id, preserve_cancellation_fence: true),
         {:ok, cancellation} <- CancellationStore.finalize_public_clear(job_id) do
      {:ok, cancellation_clear_result(cancellation)}
    end
  end

  defp maybe_cleanup_acknowledged_native_resources(job_id, true),
    do: MirrorNeuron.Runtime.RunnerResources.cleanup_native_resources(job_id)

  defp maybe_cleanup_acknowledged_native_resources(_job_id, false), do: :ok

  defp clear_terminal_job(job_id, job) do
    with :ok <- prepare_job_cleanup(job, false),
         :ok <- cleanup_job_resources(job_id, job),
         :ok <- NodeAdmission.retire(job_id),
         :ok <- RedisStore.delete_job(job_id) do
      {:ok, %{}}
    end
  end

  defp publicly_cleared_result(job_id, original_reason) do
    case CancellationStore.fetch(job_id) do
      {:ok, %{"public_cleared_at" => public_cleared_at} = cancellation}
      when is_binary(public_cleared_at) ->
        cancellation =
          case CancellationStore.finalize_public_clear(job_id) do
            {:ok, finalized} -> finalized
            _ -> cancellation
          end

        {:ok, cancellation_clear_result(cancellation)}

      _ ->
        {:error, original_reason}
    end
  end

  defp cancellation_clear_result(cancellation) do
    pending_nodes = CancellationStore.pending_nodes(cancellation)

    %{
      "cleanup_pending_nodes" => pending_nodes,
      "cleanup_deferred" => pending_nodes != []
    }
  end

  defp prepare_job_cleanup(%{"status" => status}, _force_all)
       when status in ["completed", "failed", "cancelled"],
       do: :ok

  defp prepare_job_cleanup(%{"status" => "cancelling"} = job, _force_all) do
    if CancellationStore.clearable?(job["job_id"]),
      do: :ok,
      else: {:error, :job_is_not_terminal}
  end

  defp prepare_job_cleanup(%{"job_id" => job_id}, true) do
    case JobControl.cancel_job(job_id) do
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_job_cleanup(_job, _force_all), do: {:error, :job_is_not_terminal}

  @doc false
  def cleanup_job_sandboxes(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} -> cleanup_job_sandboxes(job_id, job)
      {:error, reason} -> cleanup_job_sandboxes_without_job(job_id, reason)
    end
  end

  @doc false
  def cleanup_job_sandboxes(job_id, job) when is_map(job) or is_nil(job) do
    with {:ok, agents} <- RedisStore.list_agents(job_id) do
      JobCleanup.cleanup_sandboxes(job_id, job, agents)
    else
      {:error, reason} -> {:error, {:agent_metadata_unavailable, reason}}
    end
  end

  @doc false
  def cleanup_job_resources(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} -> cleanup_job_resources(job_id, job)
      {:error, reason} -> cleanup_job_resources_without_job(job_id, reason)
    end
  end

  @doc false
  def cleanup_job_resources(job_id, job) when is_map(job) or is_nil(job) do
    with {:ok, agents} <- RedisStore.list_agents(job_id) do
      JobCleanup.cleanup_runtime_resources(job_id, job, agents)
    else
      {:error, reason} -> {:error, {:agent_metadata_unavailable, reason}}
    end
  end

  defp cleanup_job_sandboxes_without_job(job_id, reason) do
    if is_binary(reason) and String.contains?(reason, "was not found") do
      cleanup_job_sandboxes(job_id, nil)
    else
      {:error, {:job_metadata_unavailable, reason}}
    end
  end

  defp cleanup_job_resources_without_job(job_id, reason) do
    if is_binary(reason) and String.contains?(reason, "was not found") do
      cleanup_job_resources(job_id, nil)
    else
      {:error, {:job_metadata_unavailable, reason}}
    end
  end
end
