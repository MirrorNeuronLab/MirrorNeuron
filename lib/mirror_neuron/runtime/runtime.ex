defmodule MirrorNeuron.Runtime do
  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ContextEnginePreflight
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Sandbox.JobSandbox

  alias MirrorNeuron.Runtime.{
    Backpressure,
    EventBus,
    JobRunner,
    LifecyclePolicy,
    LocalRecovery,
    ReliabilityStrategy
  }

  def start_job(manifest, opts \\ []) do
    job_id = Keyword.get(opts, :job_id, generate_job_id(manifest.graph_id))
    bundle = Keyword.get(opts, :job_bundle)

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
  end

  defp start_job_after_preflight(job_id, manifest, opts, bundle) do
    manifest_ref = bundle_ref(manifest, bundle)
    reliability = ReliabilityStrategy.resolve(manifest, manifest_ref: manifest_ref)

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
        maybe_pause_placement_failure(job_id, manifest, manifest_ref, reliability, reason)
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
           |> Keyword.put(:recovery_policy, reliability["effective_recovery_policy"]),
         :ok <-
           persist_initial_job(job_id, manifest, manifest_ref, reliability, scheduler_plan, opts) do
      publish_reliability_events(job_id, reliability)

      spec = {JobRunner, {job_id, manifest, opts}}

      case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
        {:ok, pid} ->
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
      :ok -> {:error, "failed to persist initial job"}
      {:error, reason} -> {:error, reason}
    end
  end

  def pause_job(job_id), do: call_job(job_id, :pause)

  def resume_job(job_id) do
    case call_job(job_id, :resume) do
      {:error, "job " <> _ = reason} ->
        recovery_opts =
          case pause_orphaned_active_job_for_resume(job_id, reason) do
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

      other ->
        other
    end
  end

  def cancel_job(job_id), do: call_job(job_id, :cancel)

  def cleanup_jobs(opts \\ []) do
    force_all = Keyword.get(opts, :all, false)

    case MirrorNeuron.Persistence.RedisStore.list_jobs() do
      {:ok, jobs} ->
        deleted =
          jobs
          |> Enum.filter(fn job ->
            force_all or job["status"] in ["completed", "failed", "cancelled"]
          end)
          |> Enum.map(& &1["job_id"])
          |> Enum.map(fn job_id ->
            JobSandbox.cleanup_job_local(job_id)
            MirrorNeuron.Persistence.RedisStore.delete_job(job_id)
            job_id
          end)

        {:ok, %{deleted_count: length(deleted), deleted_jobs: deleted}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_message(job_id, agent_id, message) when is_map(message) do
    call_job(job_id, {:send_message, agent_id, message})
  end

  def deploy_agents(job_id, agent_ids, manifest, scheduler_plan, deployment_context) do
    call_job(job_id, {:deploy_agents, agent_ids, manifest, scheduler_plan, deployment_context})
  end

  def pressure(job_id), do: call_job(job_id, :pressure)

  def await_completion(job_id, timeout) do
    wait_until_terminal(job_id, timeout, System.monotonic_time(:millisecond))
  end

  def deliver(job_id, agent_id, message, opts \\ []) do
    deliver_with_retry(job_id, agent_id, message, 50, opts)
  end

  defp call_job(job_id, message) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
      [{pid, _}] -> GenServer.call(pid, message, 15_000)
      [] -> {:error, "job #{job_id} is not running in the connected cluster"}
    end
  end

  defp deliver_with_retry(job_id, agent_id, message, attempts_left, opts) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _}] ->
        case preflight_delivery(pid, job_id, agent_id, opts) do
          :ok ->
            GenServer.cast(pid, {:deliver, message})
            :ok

          {:error, {:backpressure, details}} = error ->
            EventBus.publish(job_id, %{
              type: :backpressure_rejected,
              agent_id: agent_id,
              payload: details,
              timestamp: timestamp()
            })

            error
        end

      [] when attempts_left > 0 ->
        Process.sleep(50)
        deliver_with_retry(job_id, agent_id, message, attempts_left - 1, opts)

      [] ->
        EventBus.publish(job_id, %{
          type: :dead_letter,
          agent_id: agent_id,
          message: message,
          timestamp: timestamp()
        })

        {:error, "agent #{agent_id} is not running for job #{job_id}"}
    end
  end

  defp preflight_delivery(pid, job_id, agent_id, opts) do
    queue_depth = Backpressure.process_queue_depth(pid)
    pressure = Backpressure.snapshot(agent_id, %{}, queue_depth, opts)

    cond do
      Backpressure.saturated?(pressure) ->
        {:error,
         {:backpressure,
          Backpressure.retry_later_reason(pressure, %{
            "job_id" => job_id,
            "agent_id" => agent_id,
            "dropped" => true
          })}}

      Backpressure.pressured?(pressure) ->
        :ok

      true ->
        :ok
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

  @doc false
  def generate_job_id(graph_id), do: JobId.generate(graph_id)

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
    updates = %{
      "status" => "failed",
      "result" => %{
        "agent_id" => "job_runner",
        "error" => "failed to start job runner process",
        "reason" => inspect(reason)
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

    RedisStore.persist_terminal_job(job_id, updates, defaults)
  end

  defp maybe_pause_placement_failure(job_id, manifest, manifest_ref, reliability, reason) do
    if profile_placement_failure?(reason) do
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
    else
      {:error, reason}
    end
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
end
