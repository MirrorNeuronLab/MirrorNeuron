defmodule MirrorNeuron.Runtime.LocalRecovery.Recovery do
  @moduledoc "Completes interrupted finalization and restarts safe local job attempts."

  alias MirrorNeuron.Runtime.LocalRecovery.Bundles
  alias MirrorNeuron.Runtime.LocalRecovery.Eligibility
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobRunner
  alias MirrorNeuron.Runtime.RecoverySafety
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.LocalRecovery.Status

  def recover_job_map(%{"job_id" => job_id, "pending_finalization" => intent} = job, _opts)
      when is_map(intent) do
    if Eligibility.job_runner_alive?(job_id) or Eligibility.active_lease?(job_id) do
      {:ok, %{job_id: job_id, action: :skipped, reason: "finalization owner is live"}}
    else
      with {:ok, terminal} <- MirrorNeuron.Runtime.Finalization.recover(job) do
        Status.deregister_job_services(job_id)
        MirrorNeuron.Runtime.cleanup_job_sandboxes(job_id)

        MirrorNeuron.Artifacts.SharedStorage.publish_run_completion(
          terminal["manifest"],
          terminal["workflow_run_id"] || job_id,
          terminal["status"],
          terminal["lease_epoch"] || 0
        )

        EventBus.dispatch_persisted(job_id, intent["event"])
        {:ok, %{job_id: job_id, action: :skipped, reason: "terminal finalization recovered"}}
      end
    end
  end

  def recover_job_map(%{"job_id" => job_id, "status" => status} = job, opts) do
    cond do
      job["recovery_mode"] == "checkpoint_retry" and Eligibility.recoverable_job_status?(job) and
          not Eligibility.job_runner_alive?(job_id) ->
        Status.mark_recovery(
          job,
          "paused_for_review",
          "Checkpoint retry was interrupted; explicit retry is required.",
          requires_review?: true,
          status: "failed"
        )

        {:ok,
         %{job_id: job_id, action: :paused_for_review, reason: "checkpoint retry requires review"}}

      Eligibility.paused_for_review?(job) and not Keyword.get(opts, :manual_resume, false) ->
        Status.deregister_job_services(job_id)
        {:ok, %{job_id: job_id, action: :skipped, reason: "job is paused for review"}}

      not Eligibility.recoverable_job_status?(job) ->
        {:ok, %{job_id: job_id, action: :skipped, reason: "job is #{status}"}}

      Eligibility.job_runner_alive?(job_id) ->
        {:ok, %{job_id: job_id, action: :already_running, reason: "job runner is live"}}

      Eligibility.active_lease?(job_id) and not Keyword.get(opts, :ignore_lease, false) ->
        {:ok, %{job_id: job_id, action: :skipped, reason: "job lease is still active"}}

      Eligibility.cluster_recoverable_policy?(job) and
          not Keyword.get(opts, :manual_resume, false) ->
        {:ok,
         %{
           job_id: job_id,
           action: :skipped,
           reason: "job is configured for cluster recovery"
         }}

      true ->
        do_recover_job(job, opts)
    end
  end

  def recover_job_map(%{"job_id" => job_id}, _opts),
    do: {:ok, %{job_id: job_id, action: :skipped, reason: "job status is unknown"}}

  defp do_recover_job(job, opts) do
    job_id = job["job_id"]

    with {:ok, bundle} <- Bundles.load_recovery_bundle(job) do
      case recovery_decision(job, bundle.manifest, opts) do
        {:auto, reason} ->
          Status.mark_recovery(
            job,
            "auto_resuming",
            reason,
            Eligibility.auto_resume_mark_options(job)
          )

          start_recovered_job(
            job,
            bundle,
            :local_recovery_auto_resumed,
            reason,
            Keyword.get(opts, :manual_resume, false)
          )

        {:manual, reason} ->
          Status.mark_recovery(job, "paused_for_review", reason,
            requires_review?: true,
            status: "paused"
          )

          Status.deregister_job_services(job_id)

          EventBus.publish(job_id, %{
            type: :local_recovery_paused_for_review,
            mode: "clean_restart",
            reason: reason,
            timestamp: Runtime.timestamp()
          })

          {:ok, %{job_id: job_id, action: :paused_for_review, reason: reason}}
      end
    else
      {:error, reason} ->
        Status.mark_recovery(job, "paused_for_review", inspect(reason),
          requires_review?: true,
          status: "paused"
        )

        Status.deregister_job_services(job_id)

        EventBus.publish(job_id, %{
          type: :local_recovery_paused_for_review,
          reason: inspect(reason),
          blocked: true,
          timestamp: Runtime.timestamp()
        })

        {:error, "could not prepare local recovery for #{job_id}: #{inspect(reason)}"}
    end
  end

  defp recovery_decision(job, manifest, opts) do
    RecoverySafety.decision(job, manifest, [], opts)
  end

  defp start_recovered_job(job, bundle, event_type, reason, manual_resume?) do
    job_id = job["job_id"]

    opts =
      [
        job_bundle: bundle,
        local_recovery: true,
        clean_restart: true,
        manual_resume: manual_resume?,
        restart_reason: reason,
        preferred_start_node: to_string(Node.self()),
        run_id: job["run_id"] || job_id,
        stable_job_id: job["stable_job_id"],
        job_data_dir: job["job_data_dir"],
        job_data_access: job["job_data_access"],
        data_generation: job["data_generation"],
        scheduler_plan: job["scheduler"],
        admission: job["admission"],
        requested_recovery_policy: job["requested_recovery_policy"],
        recovery_policy: job["recovery_policy"],
        reliability: job["reliability"]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    bundle =
      if get_in(job, ["manifest", "metadata", "node_admission"]) do
        %{
          bundle
          | manifest:
              MirrorNeuron.Runtime.NodeAdmission.pin(
                bundle.manifest,
                get_in(job, ["admission", "generation"])
              )
        }
      else
        bundle
      end

    spec = {JobRunner, {job_id, bundle.manifest, opts}}
    stored_owner = get_in(job, ["manifest", "metadata", "node_admission", "owner_node"])

    start_result =
      if stored_owner && stored_owner != MirrorNeuron.Runtime.NodeAdmission.node_name() do
        {:error, :run_owner_unavailable}
      else
        MirrorNeuron.Runtime.NodeAdmission.run(
          if(stored_owner, do: %{"node_admission_owner" => stored_owner}, else: %{}),
          job_id,
          fn -> Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) end
        )
      end

    case start_result do
      {:ok, _pid} ->
        Status.maybe_mark_started(job, event_type, reason)

        EventBus.publish(job_id, %{
          type: event_type,
          mode: "clean_restart",
          reason: reason,
          timestamp: Runtime.timestamp()
        })

        {:ok, %{job_id: job_id, action: :started, reason: reason}}

      {:error, {:already_started, _pid}} ->
        {:ok, %{job_id: job_id, action: :already_running, reason: "job runner is live"}}

      {:error, reason} ->
        Status.mark_recovery(job, "paused_for_review", inspect(reason),
          requires_review?: true,
          status: "paused"
        )

        Status.deregister_job_services(job_id)

        {:error, "failed to start local recovery for #{job_id}: #{inspect(reason)}"}
    end
  end
end
