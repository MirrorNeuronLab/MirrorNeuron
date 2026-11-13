defmodule MirrorNeuron.Runtime.JobRunner.Startup do
  @moduledoc "Prepares clean attempts, honors restart backoff and starts the owning coordinator."

  require Logger

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AttemptController
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator
  alias MirrorNeuron.Runtime.JobRunner.Failures
  alias MirrorNeuron.Runtime.JobRunner.Leases
  alias MirrorNeuron.Runtime.JobRunner.Processes

  def acquire_and_start_coordinator(job_id, manifest, opts, lease_name, node_name) do
    case Leases.acquire_job_lease(lease_name, node_name) do
      {:ok, lease} ->
        start_coordinator_with_lease(job_id, manifest, opts, node_name, lease)

      {:error, {:locked, _owner}} ->
        stop_normally(job_id, manifest, opts, node_name)

      {:error, reason} ->
        Failures.fail_runner_start(job_id, manifest, opts, nil, reason)
    end
  end

  defp start_coordinator_with_lease(job_id, manifest, opts, node_name, lease) do
    opts = Keyword.put(opts, :job_lease, lease)

    case AttemptController.prepare(job_id, manifest, opts, lease) do
      {:ok, attempt_job} ->
        opts =
          opts
          |> Keyword.put(:attempt, attempt_job["attempt"])
          |> Keyword.put(:restart_reason, attempt_job["restart_reason"])

        with :ok <- Processes.cleanup_previous_attempt(job_id, attempt_job),
             :ok <- clear_retry_completion(manifest, opts) do
          state =
            %{
              job_id: job_id,
              manifest: manifest,
              bundle: Keyword.get(opts, :job_bundle),
              bundle_ref: Keyword.get(opts, :bundle_ref),
              opts: opts,
              coordinator: nil,
              attempt_job: attempt_job,
              node_name: node_name,
              lease: lease,
              lease_failures: 0,
              lease_timer_ref: nil,
              lease_timer_token: nil,
              coordinator_start_timer_ref: nil
            }
            |> Leases.schedule_lease_renewal()

          case AttemptController.backoff_ms(attempt_job) do
            0 ->
              case start_attempt_coordinator(state) do
                {:ok, _state} = started ->
                  started

                {:stop, _reason} = stopped ->
                  Leases.release_job_lease(job_id, node_name, lease)
                  stopped
              end

            delay_ms ->
              timer_ref = Process.send_after(self(), :start_attempt_coordinator, delay_ms)

              EventBus.publish(job_id, %{
                type: :job_attempt_backoff_started,
                mode: "clean_restart",
                attempt: attempt_job["attempt"],
                delay_ms: delay_ms,
                restart_reason: attempt_job["restart_reason"],
                lease_epoch: lease["epoch"],
                timestamp: Runtime.timestamp()
              })

              {:ok, %{state | coordinator_start_timer_ref: timer_ref}}
          end
        else
          {:error, reason} ->
            Leases.release_job_lease(job_id, node_name, lease)
            Failures.fail_runner_start(job_id, manifest, opts, lease, reason, clear_lease?: true)
        end

      {:paused, reason} ->
        Leases.release_job_lease(job_id, node_name, lease)

        EventBus.publish(job_id, %{
          type: :job_paused_for_manual_restart,
          mode: "clean_restart",
          reason: reason,
          lease_epoch: lease["epoch"],
          timestamp: Runtime.timestamp()
        })

        stop_normally(job_id, manifest, opts, node_name)

      {:exhausted, reason} ->
        case Processes.cleanup_previous_attempt(job_id, %{"restart_reason" => reason}) do
          :ok ->
            :ok

          {:error, cleanup_reason} ->
            Logger.warning(
              "restart exhaustion cleanup was incomplete for #{job_id}: #{inspect(cleanup_reason)}"
            )
        end

        Leases.release_job_lease(job_id, node_name, lease)

        EventBus.publish(job_id, %{
          type: :job_restart_attempts_exhausted,
          mode: "clean_restart",
          reason: reason,
          lease_epoch: lease["epoch"],
          timestamp: Runtime.timestamp()
        })

        stop_normally(job_id, manifest, opts, node_name)

      {:error, reason} ->
        Leases.release_job_lease(job_id, node_name, lease)
        Failures.fail_runner_start(job_id, manifest, opts, lease, reason, clear_lease?: true)
    end
  end

  defp clear_retry_completion(manifest, opts) do
    if Keyword.has_key?(opts, :checkpoint_retry),
      do:
        MirrorNeuron.Artifacts.SharedStorage.clear_run_completion(
          manifest,
          get_in(Keyword.get(opts, :checkpoint_retry), [:workflow, "run_id"]) ||
            Keyword.get(opts, :run_id),
          Keyword.fetch!(opts, :job_lease)["epoch"]
        ),
      else: :ok
  end

  def start_attempt_coordinator(state) do
    with {:ok, attempt_job} <- AttemptController.mark_started(state.job_id, state.attempt_job) do
      opts = Keyword.put(state.opts, :attempt_started_at, attempt_job["attempt_started_at"])

      case JobCoordinator.start_link({state.job_id, state.manifest, opts}) do
        {:ok, pid} ->
          EventBus.publish(state.job_id, %{
            type: :job_attempt_started,
            mode: "clean_restart",
            attempt: attempt_job["attempt"],
            attempt_started_at: attempt_job["attempt_started_at"],
            restart_reason: attempt_job["restart_reason"],
            lease_epoch: state.lease["epoch"],
            timestamp: Runtime.timestamp()
          })

          {:ok,
           %{
             state
             | coordinator: pid,
               coordinator_start_timer_ref: nil,
               attempt_job: attempt_job,
               opts: opts
           }}

        {:error, reason} ->
          Failures.fail_runner_start(
            state.job_id,
            state.manifest,
            opts,
            state.lease,
            reason,
            clear_lease?: true
          )
      end
    else
      {:error, reason} ->
        Failures.fail_runner_start(
          state.job_id,
          state.manifest,
          state.opts,
          state.lease,
          reason,
          clear_lease?: true
        )
    end
  end

  def stop_normally(job_id, manifest, opts, node_name \\ to_string(Node.self())) do
    {:ok,
     %{
       job_id: job_id,
       manifest: manifest,
       bundle: Keyword.get(opts, :job_bundle),
       bundle_ref: Keyword.get(opts, :bundle_ref),
       opts: opts,
       coordinator: nil,
       attempt_job: nil,
       node_name: node_name,
       lease: nil,
       lease_failures: 0,
       lease_timer_ref: nil,
       lease_timer_token: nil,
       coordinator_start_timer_ref: nil
     }, {:continue, :stop_normally}}
  end

  def put_bundle_ref(opts, manifest) do
    Keyword.put_new_lazy(opts, :bundle_ref, fn ->
      Runtime.bundle_ref(manifest, Keyword.get(opts, :job_bundle))
    end)
  end
end
