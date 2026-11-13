defmodule MirrorNeuron.Runtime.JobRunner.Failures do
  @moduledoc "Classifies coordinator exits and persists terminal startup failures."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AttemptController
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.EventBus

  @active_statuses ["pending", "running", "paused"]
  @terminal_statuses ["completed", "failed", "cancelled"]

  def fail_runner_start(job_id, manifest, opts, lease, reason, failure_opts \\ []) do
    Logger.warning("failed to start job coordinator for #{job_id}: #{inspect(reason)}")

    persist_runner_failure(
      job_id,
      manifest,
      Keyword.get(opts, :job_bundle),
      Keyword.get(opts, :bundle_ref),
      lease,
      opts,
      reason,
      failure_opts
    )

    {:stop, reason}
  end

  def classify_coordinator_exit(state, reason) do
    case RedisStore.fetch_job(state.job_id) do
      {:ok, %{"pending_finalization" => intent}} when is_map(intent) ->
        :recover_later

      {:ok, %{"status" => status}} when status in @terminal_statuses ->
        :terminal

      {:ok, %{"status" => "paused"}} when reason == :normal ->
        :paused

      {:ok, %{"status" => status}} when status in @active_statuses and reason == :normal ->
        Logger.info(
          "job coordinator for #{state.job_id} stopped normally while job was #{status}; leaving job active for local recovery"
        )

        EventBus.publish(state.job_id, %{
          type: :job_recovery_scheduled,
          reason: "runtime stopped before terminal state",
          exit_reason: inspect(reason),
          timestamp: Runtime.timestamp()
        })

        :recover_later

      {:ok, %{"status" => status}} when status in @active_statuses and reason != :normal ->
        Logger.warning(
          "job coordinator for #{state.job_id} exited unexpectedly; scheduling recovery: #{inspect(reason)}"
        )

        EventBus.publish(state.job_id, %{
          type: :job_recovery_scheduled,
          reason: inspect(reason),
          timestamp: Runtime.timestamp()
        })

        :restart

      _ when reason == :normal ->
        Logger.info(
          "job coordinator for #{state.job_id} stopped normally before terminal persistence; leaving existing job state for local recovery"
        )

        EventBus.publish(state.job_id, %{
          type: :job_recovery_scheduled,
          reason: "runtime stopped before terminal state",
          exit_reason: inspect(reason),
          timestamp: Runtime.timestamp()
        })

        :recover_later

      _ ->
        Logger.warning(
          "job coordinator for #{state.job_id} exited before terminal persistence: #{inspect(reason)}"
        )

        persist_runner_failure(
          state.job_id,
          state.manifest,
          state.bundle,
          state.bundle_ref,
          state.lease,
          state.opts,
          reason
        )

        :failed
    end
  end

  defp persist_runner_failure(
         job_id,
         manifest,
         bundle,
         manifest_ref,
         lease,
         opts,
         reason,
         failure_opts \\ []
       ) do
    error =
      ErrorEnvelope.normalize(reason,
        component: "job_runner",
        code: "runtime.job_runner.failed",
        agent_id: "job_runner",
        node: to_string(Node.self())
      )

    defaults =
      AttemptController.job_defaults(
        manifest,
        manifest_ref || Runtime.bundle_ref(manifest, bundle),
        lease,
        opts
      )

    updates =
      %{
        "status" => "failed",
        "result" => %{
          "agent_id" => "job_runner",
          "error" => error,
          "reason" => ErrorEnvelope.desc(error),
          "status_reason" => ErrorEnvelope.desc(error)
        }
      }
      |> maybe_clear_lease(Keyword.get(failure_opts, :clear_lease?, false))

    case RedisStore.persist_terminal_job(job_id, updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist job runner fallback state for #{job_id}: #{inspect(persist_reason)}"
        )
    end
  end

  defp maybe_clear_lease(updates, true) do
    Map.merge(updates, %{"lease" => nil, "lease_owner" => nil})
  end

  defp maybe_clear_lease(updates, false), do: updates
end
