defmodule MirrorNeuron.Runtime do
  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.{CancellationStore, RedisStore}
  alias MirrorNeuron.ContextEnginePreflight
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Scheduler

  alias MirrorNeuron.Runtime.{
    Delivery,
    ErrorEnvelope,
    EventBus,
    JobCleanup,
    JobRunner,
    LifecyclePolicy,
    LocalRecovery,
    ReliabilityStrategy
  }

  @default_job_call_timeout_ms 15_000
  @default_cancel_job_call_timeout_ms 5_000

  def job_call_timeout_ms,
    do:
      config_positive_integer(
        "MN_JOB_CALL_TIMEOUT_MS",
        :job_call_timeout_ms,
        @default_job_call_timeout_ms
      )

  def cancel_job_call_timeout_ms,
    do:
      config_positive_integer(
        "MN_CANCEL_JOB_CALL_TIMEOUT_MS",
        :cancel_job_call_timeout_ms,
        @default_cancel_job_call_timeout_ms
      )

  @doc false
  def error_message({:job_not_running, job_id}),
    do: "job #{job_id} is not running in the connected cluster"

  def error_message({:job_registry_unavailable, job_id, reason}),
    do: "job registry was unavailable while looking up job #{job_id}: #{inspect(reason)}"

  def error_message({:runtime_lookup_unavailable, job_id, reason}),
    do: "runtime metadata was unavailable while looking up job #{job_id}: #{inspect(reason)}"

  def error_message({:cluster_job_control_unavailable, job_id, node_name, reason}),
    do:
      "cluster job control was unavailable for job #{job_id} on #{node_name}: #{inspect(reason)}"

  def error_message({:redis_primary_unavailable, reason}),
    do: "Redis primary was unavailable: #{inspect(reason)}"

  def error_message({:job_call_timeout, job_id, timeout_ms}),
    do: "timed out calling job #{job_id} after #{timeout_ms}ms"

  def error_message({:job_cancelling, job_id}),
    do: "job #{job_id} has a durable cancellation in progress"

  def error_message({:job_call_failed, job_id, reason}),
    do: "job #{job_id} call failed: #{inspect(reason)}"

  def error_message({:agent_not_running, details}) do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    retry_attempts = detail(details, "retry_attempts") || 0

    "agent #{agent_id} is not running for job #{job_id} after #{retry_attempts} retries"
  end

  def error_message({:agent_unavailable, details}) do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    reason = detail(details, "reason") || detail(details, "error") || "unavailable"

    "agent #{agent_id} is unavailable for job #{job_id}: #{reason}"
  end

  def error_message({:agent_registry_unavailable, details}) do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    reason = detail(details, "reason") || detail(details, "error") || "registry unavailable"

    "agent registry was unavailable while looking up #{agent_id} for job #{job_id}: #{reason}"
  end

  def error_message({kind, details}) when kind in [:backpressure, :retry_later] do
    job_id = detail(details, "job_id") || "unknown"
    agent_id = detail(details, "agent_id") || "unknown"
    retry_after_ms = detail(details, "retry_after_ms")

    retry_suffix =
      if is_nil(retry_after_ms), do: "", else: "; retry after #{retry_after_ms}ms"

    "agent #{agent_id} for job #{job_id} is applying backpressure#{retry_suffix}"
  end

  def error_message({:invalid_live_input, reason}), do: to_string(reason)
  def error_message({:inactive_run, status}), do: "run is inactive (status: #{status})"

  def error_message({:service_run_exists, run_ids}) do
    "MN_SERVICE_RUN_EXISTS: type: service job already has a run (#{Enum.join(run_ids, ", ")}); resume, pause, cancel, delete, or explicitly replace it"
  end

  def error_message(:replacement_requires_service_job),
    do: "replace_existing_run is valid only for a type: service job"

  def error_message(:replacement_run_id_required),
    do: "a fresh explicit run_id is required when replacing a service run"

  def error_message(:replacement_run_id_must_be_fresh),
    do: "the replacement run_id must differ from every run being replaced"

  def error_message({:service_run_cleanup_failed, run_id, reason}),
    do: "failed to clean service run #{run_id}: #{error_message(reason)}"

  def error_message({:service_schedule_blocked, reason}),
    do: "service schedule is blocked: #{reason}"

  def error_message(reason) when is_binary(reason), do: reason
  def error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_message(reason), do: inspect(reason)

  def start_job(manifest, opts \\ [])

  def start_job(%MirrorNeuron.Manifest{} = manifest, opts) do
    bundle = Keyword.get(opts, :job_bundle)

    with :ok <- validate_submission_identifiers(manifest, opts),
         {:ok, job_id} <- submission_job_id(manifest, opts) do
      service_preflight =
        MirrorNeuron.ServicePreflight.run(bundle || %MirrorNeuron.JobBundle{manifest: manifest})

      with :ok <- service_preflight,
           :ok <-
             ContextEnginePreflight.ensure_available(
               Map.get(manifest, :required_context_engine, false)
             ) do
        start_job_after_preflight(job_id, manifest, opts, bundle)
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def start_job(_manifest, _opts), do: {:error, "manifest must be a normalized workflow object"}

  defp start_job_after_preflight(job_id, manifest, opts, bundle) do
    manifest_ref = bundle_ref(manifest, bundle)
    reliability = ReliabilityStrategy.resolve(manifest, manifest_ref: manifest_ref)

    :ok =
      MirrorNeuron.Artifacts.Registry.register_manifest_refs(
        MirrorNeuron.Manifest.to_map(manifest)
      )

    case Scheduler.plan(manifest, opts) do
      {:ok, scheduler_plan} ->
        start_planned_job(
          job_id,
          manifest,
          opts,
          bundle,
          manifest_ref,
          reliability,
          scheduler_plan
        )

      {:error, reason} ->
        maybe_pause_placement_failure(job_id, manifest, manifest_ref, reliability, opts, reason)
    end
  end

  defp start_planned_job(
         job_id,
         manifest,
         opts,
         _bundle,
         manifest_ref,
         reliability,
         scheduler_plan
       ) do
    with opts <-
           opts
           |> Keyword.put(:bundle_ref, manifest_ref)
           |> Keyword.put(:reliability, reliability)
           |> Keyword.put(:scheduler_plan, scheduler_plan)
           |> Keyword.put(:requested_recovery_policy, reliability["requested_recovery_policy"])
           |> Keyword.put(:recovery_policy, reliability["effective_recovery_policy"])
           |> Keyword.put_new(:preferred_start_node, to_string(Node.self())),
         :ok <-
           persist_initial_job(job_id, manifest, manifest_ref, reliability, scheduler_plan, opts) do
      publish_reliability_events(job_id, reliability)

      spec = {JobRunner, {job_id, manifest, opts}}

      case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
        {:ok, pid} ->
          {:ok, job_id, pid}

        {:error, {:already_started, pid}} ->
          {:ok, job_id, pid}

        {:error, reason} ->
          persist_startup_failure(
            job_id,
            manifest,
            manifest_ref,
            reliability,
            scheduler_plan,
            reason
          )

          {:error, "failed to start job runner: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def pause_job(job_id) do
    case cancellation_blocked?(job_id) do
      true -> {:error, {:job_cancelling, job_id}}
      false -> call_job(job_id, :pause)
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
    case call_job(job_id, :resume) do
      {:error, reason} = error ->
        if job_not_running_error?(reason) do
          recovery_opts =
            case pause_orphaned_active_job_for_resume(job_id, error_message(reason)) do
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

  def cancel_job(job_id), do: call_job(job_id, :cancel, timeout_ms: cancel_job_call_timeout_ms())

  @doc false
  def terminate_local_job(job_id) when is_binary(job_id) do
    with :ok <- terminate_local_job_runner(job_id),
         :ok <- terminate_local_agent_workers(job_id) do
      :ok
    end
  end

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
                    failure = %{"job_id" => job_id, "reason" => error_message(reason)}
                    Map.update!(acc, :failed_jobs, &[failure | &1])
                end

              {:error, reason} ->
                failure = %{"job_id" => job["job_id"], "reason" => error_message(reason)}
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
      {:ok, %{"status" => cancellation_status}}
      when cancellation_status in ["pending", "acknowledged"] ->
        clear_durable_cancellation(job_id)

      _ ->
        clear_terminal_job(job_id, job)
    end
  end

  defp clear_persisted_job(job_id, job), do: clear_terminal_job(job_id, job)

  defp clear_durable_cancellation(job_id) do
    with {:ok, _cancellation} <- CancellationStore.mark_public_cleared(job_id),
         :ok <- RedisStore.delete_job(job_id, preserve_cancellation_fence: true),
         {:ok, cancellation} <- CancellationStore.finalize_public_clear(job_id) do
      {:ok, cancellation_clear_result(cancellation)}
    end
  end

  defp clear_terminal_job(job_id, job) do
    with :ok <- prepare_job_cleanup(job, false),
         :ok <- cleanup_job_resources(job_id, job),
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
    case cancel_job(job_id) do
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_job_cleanup(_job, _force_all), do: {:error, :job_is_not_terminal}

  def send_message(job_id, agent_id, message) when is_map(message) do
    call_job(job_id, {:send_message, agent_id, message})
  end

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

  defp cancellation_blocked?(job_id) do
    match?({:ok, %{"status" => "cancelling"}}, RedisStore.fetch_job(job_id))
  end

  def deploy_agents(job_id, agent_ids, manifest, scheduler_plan, deployment_context) do
    call_job(job_id, {:deploy_agents, agent_ids, manifest, scheduler_plan, deployment_context})
  end

  def pressure(job_id), do: call_job(job_id, :pressure)

  def await_completion(job_id, timeout) do
    wait_until_terminal(job_id, timeout, System.monotonic_time(:millisecond))
  end

  def deliver(job_id, agent_id, message, _opts \\ []) do
    case Delivery.enqueue(job_id, agent_id, message) do
      {:ok, receipt} ->
        wake_delivery_consumer(job_id, agent_id)

        EventBus.publish(job_id, %{
          type: :message_queued,
          agent_id: agent_id,
          message_id: receipt.message_id,
          duplicate: receipt.status == :duplicate,
          timestamp: timestamp()
        })

        :ok

      {:error, {:delivery_backpressure, scope, count}} ->
        details = %{
          "reason" => "durable_delivery_queue_full",
          "job_id" => job_id,
          "agent_id" => agent_id,
          "scope" => to_string(scope),
          "pending" => count,
          "dropped" => false,
          "retry_after_ms" => Delivery.poll_ms()
        }

        EventBus.publish(job_id, %{
          type: :backpressure_rejected,
          agent_id: agent_id,
          payload: details,
          timestamp: timestamp()
        })

        {:error, {:backpressure, details}}

      {:error, reason} ->
        {:error, {:delivery_enqueue_failed, reason}}
    end
  end

  defp call_job(job_id, message, opts \\ []) do
    case lookup_job(job_id) do
      {:ok, pid} -> safe_job_call(job_id, pid, message, opts)
      :missing -> {:error, {:job_not_running, job_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminate_local_job_child(job_id, pid) do
    case Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.JobSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:local_job_stop_failed, job_id, reason}}
    end
  rescue
    exception ->
      {:error,
       {:local_job_stop_failed, job_id, {exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason -> {:error, {:local_job_stop_failed, job_id, {kind, reason}}}
  end

  defp terminate_local_job_runner(job_id) do
    case lookup_job_runner(job_id) do
      {:ok, pid} ->
        if node(pid) == Node.self(), do: terminate_local_job_child(job_id, pid), else: :ok

      :missing ->
        terminate_orphaned_local_coordinator(job_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminate_orphaned_local_coordinator(job_id) do
    case lookup_job(job_id) do
      {:ok, pid} ->
        if node(pid) == Node.self() do
          Process.exit(pid, :shutdown)
        end

        :ok

      _missing_or_remote ->
        :ok
    end
  end

  # Agent workers are supervised independently from their job runner. A durable
  # cancellation must stop them explicitly after the runner is removed, or they
  # can continue to emit fenced observations and retain service registrations.
  defp terminate_local_agent_workers(job_id) do
    with {:ok, observations} <- RedisStore.list_agents(job_id) do
      observations
      |> Enum.map(&(Map.get(&1, "agent_id") || Map.get(&1, "node_id")))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn agent_id, :ok ->
        case terminate_local_agent_worker(job_id, agent_id) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:local_agent_stop_failed, job_id, agent_id, reason}}}
        end
      end)
    end
  end

  defp terminate_local_agent_worker(job_id, agent_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _metadata} | _] ->
        if node(pid) == Node.self() do
          case DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.LocalAgentSupervisor, pid) do
            :ok -> :ok
            {:error, :not_found} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          :ok
        end

      _missing_or_remote ->
        :ok
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp lookup_job(job_id) do
    case safe_registry_lookup({:job, job_id}) do
      {:ok, [{pid, _meta} | _]} -> {:ok, pid}
      {:ok, []} -> :missing
      {:error, reason} -> {:error, {:job_registry_unavailable, job_id, reason}}
    end
  end

  defp lookup_job_runner(job_id) do
    case safe_registry_lookup({:job_runner, job_id}) do
      {:ok, [{pid, _meta} | _]} -> {:ok, pid}
      {:ok, []} -> :missing
      {:error, reason} -> {:error, {:job_registry_unavailable, job_id, reason}}
    end
  end

  defp safe_job_call(job_id, pid, message, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, job_call_timeout_ms())

    try do
      GenServer.call(pid, message, timeout_ms)
    catch
      :exit, reason ->
        error = normalize_job_call_exit(reason, job_id, timeout_ms)
        maybe_log_job_call_error(error, job_id, message)
        {:error, error}
    end
  end

  defp normalize_job_call_exit({:timeout, _call}, job_id, timeout_ms),
    do: {:job_call_timeout, job_id, timeout_ms}

  defp normalize_job_call_exit({:noproc, _call}, job_id, _timeout_ms),
    do: {:job_not_running, job_id}

  defp normalize_job_call_exit({:normal, _call}, job_id, _timeout_ms),
    do: {:job_not_running, job_id}

  defp normalize_job_call_exit(reason, job_id, _timeout_ms),
    do: {:job_call_failed, job_id, reason}

  defp maybe_log_job_call_error({:job_not_running, _reason_job_id}, _job_id, _message), do: :ok

  defp maybe_log_job_call_error(reason, job_id, message) do
    Logger.warning(
      "runtime job call failed",
      job_id: job_id,
      message: inspect(message),
      reason: error_message(reason)
    )
  end

  defp wake_delivery_consumer(job_id, agent_id) do
    case safe_registry_lookup({:agent, job_id, agent_id}) do
      {:ok, [{pid, _meta} | _]} -> GenServer.cast(pid, :delivery_available)
      _missing_or_unavailable -> :ok
    end
  end

  defp safe_registry_lookup(key) do
    try do
      {:ok, Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, key)}
    rescue
      exception -> {:error, {exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
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
    case call_job(job_id, :resume) do
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
    now = timestamp()

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

  @doc false
  def generate_job_id(graph_id), do: JobId.generate(graph_id)

  defp validate_submission_identifiers(manifest, opts) do
    with :ok <- validate_identifier("graph_id", manifest.graph_id),
         :ok <- validate_identifier("job_name", manifest.job_name),
         :ok <- validate_optional_identifier("job_id", Keyword.get(opts, :job_id)) do
      :ok
    end
  end

  defp submission_job_id(manifest, opts) do
    case Keyword.get(opts, :job_id) do
      nil -> {:ok, generate_job_id(manifest.graph_id)}
      job_id -> {:ok, job_id}
    end
  end

  defp validate_optional_identifier(_field, nil), do: :ok
  defp validate_optional_identifier(field, value), do: validate_identifier(field, value)

  defp validate_identifier(field, value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, "#{field} must be a non-empty string"}
    else
      :ok
    end
  end

  defp validate_identifier(field, _value), do: {:error, "#{field} must be a non-empty string"}

  @doc false
  def bundle_ref(manifest, bundle) do
    base_ref = %{
      "graph_id" => manifest.graph_id,
      "manifest_version" => manifest.manifest_version,
      "manifest_path" => bundle && bundle.manifest_path,
      "job_path" => bundle && bundle.root_path
    }

    case Archive.store(bundle) do
      {:ok, archive_ref} ->
        base_ref
        |> Map.put("bundle_fingerprint", archive_ref.fingerprint)
        |> Map.put("bundle_storage", archive_ref.storage)
        |> Map.put("bundle_bytes", archive_ref.total_bytes)
        |> Map.put("cache_path", Archive.cache_path(archive_ref.fingerprint))

      {:error, _reason} ->
        base_ref
    end
  end

  def timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp persist_startup_failure(
         job_id,
         manifest,
         manifest_ref,
         reliability,
         scheduler_plan,
         reason
       ) do
    error =
      ErrorEnvelope.normalize(reason,
        component: "runtime",
        code: "runtime.job_runner.failed",
        agent_id: "job_runner",
        node: to_string(Node.self())
      )

    updates = %{
      "status" => "failed",
      "result" => %{
        "agent_id" => "job_runner",
        "error" => error,
        "reason" => ErrorEnvelope.desc(error),
        "status_reason" => ErrorEnvelope.desc(error)
      }
    }

    defaults =
      %{
        "graph_id" => manifest.graph_id,
        "job_name" => manifest.job_name,
        "required_context_engine" => required_context_engine(manifest),
        "root_agent_ids" => manifest.entrypoints,
        "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
        "job_type" => scheduler_plan["job_type"],
        "scheduler" => scheduler_plan,
        "requested_recovery_policy" => reliability["requested_recovery_policy"],
        "recovery_policy" => reliability["effective_recovery_policy"],
        "reliability_degraded" => reliability["reliability_degraded"],
        "reliability" => reliability_map(reliability),
        "manifest_ref" => manifest_ref,
        "submitted_at" => timestamp()
      }
      |> Map.merge(policy_fields(manifest, reliability, scheduler_plan))

    case RedisStore.persist_terminal_job(job_id, updates, defaults) do
      {:ok, _job} = ok ->
        EventBus.publish(job_id, %{
          type: :job_failed,
          agent_id: "job_runner",
          error: error,
          reason: ErrorEnvelope.desc(error),
          status_reason: ErrorEnvelope.desc(error),
          timestamp: timestamp()
        })

        ok

      other ->
        other
    end
  end

  defp maybe_pause_placement_failure(job_id, manifest, manifest_ref, reliability, opts, reason) do
    cond do
      profile_placement_failure?(reason) ->
        review_reason = profile_placement_review_reason(manifest, reason)
        scheduler_plan = placement_failure_plan(manifest, reason)

        with :ok <-
               persist_initial_job(job_id, manifest, manifest_ref, reliability, scheduler_plan),
             {:ok, _job} <-
               RedisStore.persist_terminal_job(
                 job_id,
                 placement_pause_updates(review_reason),
                 placement_pause_defaults(manifest, manifest_ref, reliability, scheduler_plan)
               ) do
          publish_reliability_events(job_id, reliability)

          EventBus.publish(job_id, %{
            type: :job_paused_for_manual_restart,
            reason: review_reason,
            execution_profile: placement_failure_profile(manifest),
            timestamp: timestamp()
          })

          {:ok, job_id, nil}
        else
          {:error, persist_reason} -> {:error, persist_reason}
          other -> {:error, "failed to persist placement pause: #{inspect(other)}"}
        end

      resources_temporarily_unavailable?(manifest, opts) ->
        {:error,
         "resource_overloaded: no runtime resources are available to run this workflow now; " <>
           "wait for active jobs to finish or cancel a paused job that holds the required resources. " <>
           reason}

      true ->
        {:error, reason}
    end
  end

  defp resources_temporarily_unavailable?(manifest, opts) do
    match?({:blocked, _}, Scheduler.availability(manifest, opts))
  end

  defp profile_placement_failure?(reason) do
    reason = to_string(reason)
    String.contains?(reason, "execution profile not available")
  end

  defp profile_placement_review_reason(manifest, fallback_reason) do
    profiles = placement_failure_profiles(manifest)

    case profiles do
      [profile] -> "execution profile #{profile} has no eligible runtime nodes"
      [_ | _] -> "execution profiles #{Enum.join(profiles, ", ")} have no eligible runtime nodes"
      [] -> fallback_reason
    end
  end

  defp placement_failure_profile(manifest) do
    case placement_failure_profiles(manifest) do
      [profile] -> profile
      profiles when profiles != [] -> Enum.join(profiles, ",")
      [] -> nil
    end
  end

  defp placement_failure_profiles(manifest) do
    manifest.nodes
    |> Enum.map(&MirrorNeuron.Execution.Profile.profile_name(&1.config))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp placement_failure_plan(manifest, reason) do
    job_type =
      case Scheduler.job_type(manifest) do
        {:ok, type} -> type
        {:error, _reason} -> manifest.type || "batch"
      end

    %{
      "status" => "placement_failed",
      "job_type" => job_type,
      "strategy" => "unknown",
      "mode" => "unknown",
      "placement_count" => 0,
      "placements" => [],
      "requirements" => %{},
      "reason" => reason,
      "generated_at" => timestamp()
    }
  end

  defp placement_pause_updates(reason) do
    now = timestamp()

    recovery = %{
      "status" => "paused_for_review",
      "reason" => reason,
      "requires_review" => true,
      "can_resume" => true,
      "updated_at" => now
    }

    %{
      "status" => "paused",
      "updated_at" => now,
      "result" => %{"agent_id" => "scheduler", "error" => reason},
      "recovery" => recovery,
      "recovery_status" => "paused_for_review",
      "recovery_reason" => reason,
      "recovery_requires_review" => true
    }
  end

  defp placement_pause_defaults(manifest, manifest_ref, reliability, scheduler_plan) do
    %{
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "required_context_engine" => required_context_engine(manifest),
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "job_type" => scheduler_plan["job_type"],
      "scheduler" => scheduler_plan,
      "requested_recovery_policy" => reliability["requested_recovery_policy"],
      "recovery_policy" => reliability["effective_recovery_policy"],
      "reliability_degraded" => reliability["reliability_degraded"],
      "reliability" => reliability_map(reliability),
      "manifest" => MirrorNeuron.Manifest.to_map(manifest),
      "manifest_ref" => manifest_ref,
      "submitted_at" => timestamp()
    }
    |> Map.merge(policy_fields(manifest, reliability, scheduler_plan))
  end

  defp persist_initial_job(
         job_id,
         manifest,
         manifest_ref,
         reliability,
         scheduler_plan,
         opts \\ []
       ) do
    job_map =
      %{
        "job_id" => job_id,
        "run_id" => Keyword.get(opts, :run_id, job_id),
        "stable_job_id" => Keyword.get(opts, :stable_job_id),
        "attempt_id" => "#{Keyword.get(opts, :run_id, job_id)}:1",
        "job_data_dir" => Keyword.get(opts, :job_data_dir),
        "job_data_access" => Keyword.get(opts, :job_data_access),
        "data_generation" => Keyword.get(opts, :data_generation),
        "graph_id" => manifest.graph_id,
        "job_name" => manifest.job_name,
        "type" => manifest.type,
        "required_context_engine" => required_context_engine(manifest),
        "status" => "pending",
        "submitted_at" => timestamp(),
        "updated_at" => timestamp(),
        "root_agent_ids" => manifest.entrypoints,
        "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
        "job_type" => scheduler_plan["job_type"],
        "scheduler" => scheduler_plan,
        "requested_recovery_policy" => reliability["requested_recovery_policy"],
        "recovery_policy" => reliability["effective_recovery_policy"],
        "reliability_degraded" => reliability["reliability_degraded"],
        "reliability" => reliability_map(reliability),
        "result" => nil,
        "topology" => MirrorNeuron.Manifest.topology(manifest),
        "manifest" => MirrorNeuron.Manifest.to_map(manifest),
        "manifest_ref" => manifest_ref,
        "deployment" => stringify_map(Keyword.get(opts, :deployment_context, %{}))
      }
      |> Map.merge(policy_fields(manifest, reliability, scheduler_plan))

    case RedisStore.persist_job(job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_context_engine(manifest), do: Map.get(manifest, :required_context_engine, false)

  defp reliability_map(reliability) do
    Map.take(reliability, [
      "mode",
      "effective_recovery_policy",
      "degraded",
      "reason",
      "observed_nodes",
      "observed_at"
    ])
  end

  defp policy_fields(manifest, reliability, scheduler_plan) do
    policies =
      LifecyclePolicy.normalize(
        manifest,
        scheduler_plan["job_type"],
        reliability["effective_recovery_policy"]
      )

    Map.put(policies, "policy_state", %{"agents" => %{}})
  end

  defp publish_reliability_events(job_id, reliability) do
    EventBus.publish(job_id, %{
      type: :reliability_strategy_resolved,
      requested_recovery_policy: reliability["requested_recovery_policy"],
      effective_recovery_policy: reliability["effective_recovery_policy"],
      mode: reliability["mode"],
      degraded: reliability["reliability_degraded"],
      reason: reliability["reason"],
      observed_nodes: reliability["observed_nodes"],
      timestamp: timestamp()
    })

    if reliability["reliability_degraded"] do
      EventBus.publish(job_id, %{
        type: :job_reliability_degraded,
        mode: reliability["mode"],
        reason: reliability["reason"],
        observed_nodes: reliability["observed_nodes"],
        timestamp: timestamp()
      })
    end
  end

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> app_positive_integer(key, default)
      "" -> app_positive_integer(key, default)
      value -> positive_integer(value, app_positive_integer(key, default))
    end
  end

  defp app_positive_integer(key, default) do
    case Application.get_env(:mirror_neuron, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp positive_integer(value, default) do
    case parse_integer(value, default) do
      parsed when is_integer(parsed) and parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp detail(details, key) when is_map(details) do
    Map.get(details, key) || Map.get(details, String.to_atom(key))
  end

  defp detail(_details, _key), do: nil
end
