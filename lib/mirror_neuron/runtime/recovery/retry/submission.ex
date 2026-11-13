defmodule MirrorNeuron.Runtime.RunRetry.Submission do
  @moduledoc "Idempotent retry submission, queued admission and fenced attempt initialization."

  alias MirrorNeuron.Runtime.RunRetry.Checkpoints
  alias MirrorNeuron.Runtime.RunRetry.Configuration
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobRunner
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.RunRetry.Planner
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Runtime.WorkflowRetry

  def submit(run_id, attrs) do
    with {:ok, job} <- RedisStore.fetch_job(run_id) do
      StableJob.with_start_gate(job["stable_job_id"] || run_id, fn ->
        with {:ok, current} <- RedisStore.fetch_job(run_id) do
          key = attrs["idempotency_key"]

          cond do
            not is_binary(key) or byte_size(key) not in 1..255 ->
              {:error, {:invalid_run_retry, "An idempotency key is required."}}

            is_map(get_in(current, ["retry_receipts", key])) ->
              saved = current["retry_receipts"][key]

              if saved["request_digest"] == Checkpoints.digest(attrs),
                do: {:ok, saved["receipt"]},
                else:
                  {:error,
                   {:run_retry_blocked, "Idempotency key was used for different retry settings."}}

            true ->
              do_submit(current, attrs)
          end
        end
      end)
    end
  end

  defp do_submit(job, attrs, admitted \\ false) do
    with {:ok, prepared} <- Planner.prepare(job, attrs["configuration_overrides"] || %{}),
         true <-
           attrs["expected_attempt"] == job["attempt"] and
             attrs["checkpoint_revision"] == prepared.checkpoint["revision"],
         :ok <- Planner.inactive(job),
         {:ok, workflow} <- WorkflowRetry.restore(prepared.ledger, Runtime.timestamp()) do
      request =
        attrs
        |> Map.put("request_digest", Checkpoints.digest(attrs))
        |> Map.put(
          "effective_configuration_overrides",
          Map.merge(
            Configuration.effective_overrides(job),
            attrs["configuration_overrides"] || %{}
          )
        )

      opts = [
        job_bundle: prepared.bundle,
        bundle_ref: job["manifest_ref"],
        checkpoint_retry: %{job: job, workflow: workflow, request: request},
        run_id: job["run_id"] || job["job_id"],
        stable_job_id: job["stable_job_id"],
        data_generation: job["data_generation"],
        job_data_dir: job["job_data_dir"],
        job_data_access: job["job_data_access"],
        scheduler_plan: job["scheduler"],
        requested_recovery_policy: job["requested_recovery_policy"],
        recovery_policy: job["recovery_policy"],
        reliability: job["reliability"]
      ]

      start = fn manifest ->
        admission =
          case MirrorNeuron.Runtime.NodeAdmission.receipt(job["job_id"]) do
            {:ok, receipt} -> receipt
            _ -> job["admission"]
          end

        opts = Keyword.put(opts, :admission, admission)

        Horde.DynamicSupervisor.start_child(
          MirrorNeuron.Runtime.JobSupervisor,
          {JobRunner,
           {job["job_id"], manifest,
            Keyword.put(opts, :job_bundle, %{prepared.bundle | manifest: manifest})}}
        )
      end

      result =
        if admitted do
          with {:ok, receipt} <- MirrorNeuron.Runtime.NodeAdmission.receipt(job["job_id"]) do
            start.(
              MirrorNeuron.Runtime.NodeAdmission.pin(
                prepared.bundle.manifest,
                receipt["generation"],
                receipt["allocation"]
              )
            )
          end
        else
          MirrorNeuron.Runtime.NodeAdmission.retry(job, prepared.bundle.manifest, request, start)
        end

      case result do
        {:queued, receipt} ->
          {:ok, receipt}

        {:ok, _pid} ->
          {:ok, current} = RedisStore.fetch_job(job["job_id"])

          EventBus.publish(job["job_id"], %{
            type: :run_retry_accepted,
            attempt: current["attempt"],
            checkpoint_revision: prepared.checkpoint["revision"],
            timestamp: Runtime.timestamp()
          })

          {:ok, current["retry_receipts"][attrs["idempotency_key"]]["receipt"]}

        {:error, reason} ->
          {:error,
           {:run_retry_blocked, "Retry could not start: #{Runtime.error_message(reason)}"}}
      end
    else
      false -> {:error, {:run_retry_blocked, "The run changed. Review the retry plan again."}}
      {:error, {_kind, _reason}} = error -> error
      {:error, reason} -> {:error, {:run_retry_blocked, reason}}
    end
  end

  @doc false
  def dispatch_queued(%{"queued_retry" => request} = job) do
    # Admission holds this run's start gate. Reverify the original checkpoint
    # and inputs before opening a new attempt; never turn a retry into fresh work.
    case do_submit(
           Map.put(job, "status", "failed"),
           Map.drop(request, ["request_digest", "effective_configuration_overrides"]),
           true
         ) do
      {:ok, _} -> {:ok, job["job_id"], nil}
      error -> error
    end
  end

  # Called only after JobRunner has acquired a new fenced lease.

  def begin_attempt(job_id, manifest, %{job: prior, workflow: workflow, request: request}, lease) do
    with {:ok, current} <- RedisStore.fetch_job(job_id),
         true <-
           (current["status"] == "failed" or
              (current["status"] == "queued" and
                 get_in(current, ["queued_retry", "request_digest"]) == request["request_digest"])) and
             current["attempt"] == prior["attempt"] do
      attempt = prior["attempt"] + 1

      history =
        List.wrap(prior["attempt_history"]) ++
          [
            %{
              "attempt" => prior["attempt"],
              "action" => "failed",
              "result_ref" => prior["result_ref"],
              "at" => prior["updated_at"]
            },
            %{
              "attempt" => attempt,
              "action" => "checkpoint_retry",
              "at" => Runtime.timestamp(),
              "checkpoint_revision" => request["checkpoint_revision"],
              "configuration_overrides" => request["configuration_overrides"] || %{}
            }
          ]

      accepted = %{
        "run_id" => prior["run_id"] || job_id,
        "job_id" => prior["stable_job_id"],
        "attempt" => attempt,
        "attempt_id" => "#{prior["run_id"] || job_id}:#{attempt}",
        "status" => "accepted"
      }

      receipts =
        Map.put(prior["retry_receipts"] || %{}, request["idempotency_key"], %{
          "request_digest" => request["request_digest"],
          "receipt" => accepted
        })

      RedisStore.persist_terminal_job(job_id, %{
        "status" => "pending",
        "attempt" => attempt,
        "attempt_id" => "#{prior["run_id"] || job_id}:#{attempt}",
        "workflow_state" => workflow,
        "manifest" => Manifest.to_map(manifest),
        "restart_reason" => "checkpoint_retry",
        "recovery_mode" => "checkpoint_retry",
        "retry_request" => request,
        "queued_retry" => nil,
        "attempt_history" => history,
        "retry_receipts" => receipts,
        "pending_workflow_completion" => nil,
        "recovery_requires_review" => false,
        "recovery" => nil,
        "attempt_started_at" => nil,
        "attempt_not_before" => nil,
        "restart_budget" => nil,
        "result" => nil,
        "result_ref" => nil,
        "workflow_state_ref" => nil,
        "lease" => lease,
        "lease_epoch" => lease["epoch"],
        "lease_owner" => lease["owner_id"]
      })
    else
      _ -> {:error, {:run_retry_blocked, "The failed run changed before retry."}}
    end
  end
end
