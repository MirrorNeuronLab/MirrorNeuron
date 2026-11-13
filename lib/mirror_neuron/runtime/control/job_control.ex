defmodule MirrorNeuron.Runtime.JobControl do
  @moduledoc "Pause, resume, cancellation and completion waiting through the run owner."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ControlErrors
  alias MirrorNeuron.Runtime.ControlSettings
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCalls
  alias MirrorNeuron.Runtime.LocalRecovery
  alias MirrorNeuron.Runtime.NodeAdmission

  def pause_job(job_id) do
    case cancellation_blocked?(job_id) do
      true -> {:error, {:job_cancelling, job_id}}
      false -> JobCalls.call_job(job_id, :pause)
    end
  end

  def resume_job(job_id) do
    case cancellation_blocked?(job_id) do
      true ->
        {:error, {:job_cancelling, job_id}}

      false ->
        resume_unblocked_job(job_id)
    end
  end

  defp resume_unblocked_job(job_id) do
    case JobCalls.call_job(job_id, :resume) do
      {:error, reason} = error ->
        if job_not_running_error?(reason) do
          recovery_opts =
            case pause_orphaned_active_job_for_resume(job_id, ControlErrors.error_message(reason)) do
              :paused -> [manual_resume: true, ignore_lease: true]
              :unchanged -> [manual_resume: true]
            end

          case LocalRecovery.recover_job(job_id, recovery_opts) do
            {:ok, %{action: action}} when action in [:started, :already_running] ->
              resume_recovered_job(job_id)

            {:ok, %{action: :paused_for_review}} ->
              resume_recovered_job(job_id)

            {:ok, %{action: :skipped, reason: _skip_reason}} ->
              {:error, reason}

            {:error, recover_reason} ->
              {:error, recover_reason}
          end
        else
          error
        end

      other ->
        other
    end
  end

  def cancel_job(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => "queued"}} ->
        case NodeAdmission.cancel(job_id) do
          :ok -> {:ok, %{"job_id" => job_id, "status" => "cancelled"}}
          error -> error
        end

      _ ->
        JobCalls.call_job(job_id, :cancel,
          timeout_ms: ControlSettings.cancel_job_call_timeout_ms()
        )
    end
  end

  def send_message(job_id, agent_id, message) when is_map(message) do
    JobCalls.call_job(job_id, {:send_message, agent_id, message})
  end

  defp cancellation_blocked?(job_id) do
    match?({:ok, %{"status" => "cancelling"}}, RedisStore.fetch_job(job_id))
  end

  def deploy_agents(job_id, agent_ids, manifest, scheduler_plan, deployment_context) do
    JobCalls.call_job(
      job_id,
      {:deploy_agents, agent_ids, manifest, scheduler_plan, deployment_context}
    )
  end

  def pressure(job_id), do: JobCalls.call_job(job_id, :pressure)

  def await_completion(job_id, timeout) do
    wait_until_terminal(job_id, timeout, System.monotonic_time(:millisecond))
  end

  defp wait_until_terminal(job_id, timeout, started_at) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["completed", "failed", "cancelled"] ->
        {:ok, job}

      {:ok, _job} ->
        if timeout != :infinity and System.monotonic_time(:millisecond) - started_at > timeout do
          {:error, "timed out waiting for job #{job_id}"}
        else
          Process.sleep(100)
          wait_until_terminal(job_id, timeout, started_at)
        end

      {:error, _reason} ->
        if timeout != :infinity and System.monotonic_time(:millisecond) - started_at > timeout do
          {:error, "timed out waiting for job #{job_id}"}
        else
          Process.sleep(100)
          wait_until_terminal(job_id, timeout, started_at)
        end
    end
  end

  defp resume_recovered_job(job_id) do
    case JobCalls.call_job(job_id, :resume) do
      {:ok, "resumed"} ->
        {:ok, "resumed"}

      {:error, "job is not paused"} ->
        {:ok, "resumed"}

      other ->
        other
    end
  end

  defp pause_orphaned_active_job_for_resume(job_id, original_reason) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["pending", "running"] ->
        if local_recovery_policy?(job) do
          reason =
            "job runner was missing while job was marked #{status}; " <>
              "assuming local runtime interruption and pausing for manual resume"

          case pause_job_for_manual_resume(job, reason, original_reason) do
            :ok ->
              release_orphaned_job_lease(job_id, job)
              :paused

            :error ->
              :unchanged
          end
        else
          :unchanged
        end

      _ ->
        :unchanged
    end
  end

  defp pause_job_for_manual_resume(job, reason, original_reason) do
    now = Runtime.timestamp()

    recovery = %{
      "status" => "paused_for_review",
      "reason" => reason,
      "requires_review" => true,
      "can_resume" => true,
      "updated_at" => now
    }

    updates =
      job
      |> Map.merge(%{
        "status" => "paused",
        "updated_at" => now,
        "recovery" => recovery,
        "recovery_status" => "paused_for_review",
        "recovery_reason" => reason,
        "recovery_requires_review" => true
      })

    case RedisStore.persist_job(job["job_id"], updates) do
      {:ok, _job} ->
        EventBus.publish(job["job_id"], %{
          type: :job_paused_for_manual_resume,
          reason: reason,
          original_error: original_reason,
          timestamp: now
        })

        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to pause orphaned job #{job["job_id"]} for manual resume: #{inspect(persist_reason)}"
        )

        :error
    end
  end

  defp release_orphaned_job_lease(job_id, job) do
    owner = job["lease_owner"] || get_in(job, ["lease", "owner_id"])
    epoch = job["lease_epoch"] || get_in(job, ["lease", "epoch"])

    if is_binary(owner) and not is_nil(epoch) do
      _ = RedisStore.release_fenced_lease("job:#{job_id}", owner, epoch)
    end
  end

  defp local_recovery_policy?(job) do
    Map.get(job, "recovery_policy", "local_restart") != "cluster_recover"
  end

  defp job_not_running_error?({:job_not_running, _job_id}), do: true

  defp job_not_running_error?(reason) when is_binary(reason),
    do: String.starts_with?(reason, "job ") and String.contains?(reason, "not running")

  defp job_not_running_error?(_reason), do: false
end
