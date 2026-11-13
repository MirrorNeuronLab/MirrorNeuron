defmodule MirrorNeuron.Runtime.PlacementFailure do
  @moduledoc "Records a manual review pause when required execution profiles are unavailable."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.InitialRecords
  alias MirrorNeuron.Scheduler

  def maybe_pause_placement_failure(job_id, manifest, manifest_ref, reliability, opts, reason) do
    cond do
      profile_placement_failure?(reason) ->
        review_reason = profile_placement_review_reason(manifest, reason)
        scheduler_plan = placement_failure_plan(manifest, reason)

        with :ok <-
               InitialRecords.persist_initial_job(
                 job_id,
                 manifest,
                 manifest_ref,
                 reliability,
                 scheduler_plan
               ),
             {:ok, _job} <-
               RedisStore.persist_terminal_job(
                 job_id,
                 placement_pause_updates(review_reason),
                 placement_pause_defaults(manifest, manifest_ref, reliability, scheduler_plan)
               ) do
          InitialRecords.publish_reliability_events(job_id, reliability)

          EventBus.publish(job_id, %{
            type: :job_paused_for_manual_restart,
            reason: review_reason,
            execution_profile: placement_failure_profile(manifest),
            timestamp: Runtime.timestamp()
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
      "generated_at" => Runtime.timestamp()
    }
  end

  defp placement_pause_updates(reason) do
    now = Runtime.timestamp()

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
      "required_context_engine" => InitialRecords.required_context_engine(manifest),
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "job_type" => scheduler_plan["job_type"],
      "scheduler" => scheduler_plan,
      "requested_recovery_policy" => reliability["requested_recovery_policy"],
      "recovery_policy" => reliability["effective_recovery_policy"],
      "reliability_degraded" => reliability["reliability_degraded"],
      "reliability" => InitialRecords.reliability_map(reliability),
      "manifest" => MirrorNeuron.Manifest.to_map(manifest),
      "manifest_ref" => manifest_ref,
      "submitted_at" => Runtime.timestamp()
    }
    |> Map.merge(InitialRecords.policy_fields(manifest, reliability, scheduler_plan))
  end
end
