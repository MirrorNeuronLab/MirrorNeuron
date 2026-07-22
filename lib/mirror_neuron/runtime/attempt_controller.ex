defmodule MirrorNeuron.Runtime.AttemptController do
  @moduledoc """
  Owns the durable control transition for whole-job attempts.

  An attempt is rebuilt from the persisted manifest and declared inputs. This
  module deliberately does not read agent observations, workflow ledgers, or
  checkpoints when deciding or preparing a restart.
  """

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{LifecyclePolicy, RecoverySafety}

  def prepare(job_id, manifest, opts, lease) do
    with {:ok, existing} <- RedisStore.fetch_job(job_id) do
      initial? = Map.get(existing, "attempt", 0) == 0 and existing["status"] == "pending"

      decision =
        if initial? do
          {:auto, "initial job attempt"}
        else
          RecoverySafety.decision(existing, manifest, [], opts)
        end

      case decision do
        {:auto, decision_reason} ->
          case restart_budget(existing, manifest, opts, initial?) do
            {:ok, budget} ->
              begin_attempt(
                existing,
                manifest,
                opts,
                lease,
                initial?,
                decision_reason,
                budget
              )

            {:exhausted, details} ->
              fail_exhausted_attempt(existing, manifest, opts, lease, details)
          end

        {:manual, reason} ->
          pause_for_approval(existing, lease, reason)
      end
    end
  end

  def backoff_ms(%{"restart_budget" => %{"delay_ms" => delay_ms}})
      when is_integer(delay_ms) and delay_ms > 0,
      do: delay_ms

  def backoff_ms(_attempt_job), do: 0

  def mark_started(job_id, attempt_job) do
    started_at = Runtime.timestamp()
    attempt = attempt_job["attempt"]

    attempt_history =
      Enum.map(List.wrap(attempt_job["attempt_history"]), fn
        %{"attempt" => ^attempt} = entry -> Map.put(entry, "started_at", started_at)
        entry -> entry
      end)

    updates = %{
      "status" => "running",
      "attempt_started_at" => started_at,
      "attempt_not_before" => nil,
      "attempt_history" => attempt_history
    }

    case RedisStore.persist_terminal_job(job_id, updates, attempt_job) do
      {:ok, started_job} -> {:ok, started_job}
      {:error, reason} -> {:error, {:attempt_start_persist_failed, reason}}
    end
  end

  def job_defaults(manifest, manifest_ref, lease, opts) do
    reliability = reliability_from(manifest, opts)
    scheduler_plan = scheduler_plan(manifest, opts)

    %{
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "required_context_engine" => Map.get(manifest, :required_context_engine, false),
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
      "deployment" => stringify_map(Keyword.get(opts, :deployment_context, %{})),
      "submitted_at" => Runtime.timestamp()
    }
    |> Map.merge(policy_fields(manifest, reliability, scheduler_plan))
    |> maybe_put_lease(lease)
  end

  defp begin_attempt(existing, manifest, opts, lease, initial?, decision_reason, budget) do
    attempt = max(integer_value(existing["attempt"], 0), 0) + 1
    now = Runtime.timestamp()

    restart_reason =
      if initial?,
        do: "initial_start",
        else: Keyword.get(opts, :restart_reason, decision_reason || "runtime_owner_lost")

    history =
      if initial? do
        List.wrap(existing["attempt_history"])
      else
        List.wrap(existing["attempt_history"]) ++
          [
            %{
              "attempt" => attempt,
              "action" => "restart",
              "reason" => to_string(restart_reason),
              "at" => now,
              "started_at" => nil,
              "lease_epoch" => lease["epoch"]
            }
          ]
      end

    updates = %{
      "status" => "pending",
      "result" => nil,
      "result_ref" => nil,
      "workflow_state" => nil,
      "workflow_state_ref" => nil,
      "pending_workflow_completion" => nil,
      "policy_state" => %{"agents" => %{}},
      "attempt" => attempt,
      "attempt_started_at" => nil,
      "attempt_not_before" => attempt_not_before(budget),
      "attempt_history" => Enum.take(history, -50),
      "restart_budget" => budget,
      "restart_reason" => restart_reason,
      "recovery_mode" => "clean_restart",
      "recovery_status" => if(initial?, do: nil, else: "clean_restarted"),
      "recovery_reason" => if(initial?, do: nil, else: restart_reason),
      "recovery_requires_review" => false,
      "recovery" => %{
        "mode" => "clean_restart",
        "status" => if(initial?, do: "initial_attempt", else: "clean_restarted"),
        "reason" => restart_reason,
        "requires_review" => false,
        "can_resume" => false,
        "updated_at" => now
      },
      "lease" => lease,
      "lease_epoch" => lease["epoch"],
      "lease_owner" => lease["owner_id"]
    }

    defaults = job_defaults(manifest, Keyword.get(opts, :bundle_ref), lease, opts)

    case RedisStore.persist_terminal_job(existing["job_id"], updates, defaults) do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:attempt_persist_failed, reason}}
    end
  end

  defp restart_budget(_existing, _manifest, _opts, true), do: {:ok, nil}

  defp restart_budget(existing, manifest, opts, false) do
    if Keyword.get(opts, :manual_resume, false) do
      {:ok, %{"authorized_by" => "operator", "attempts_remaining" => nil}}
    else
      job_type = existing["job_type"] || manifest.type || "batch"

      policy =
        existing["restart_policy"] ||
          LifecyclePolicy.restart_policy(
            manifest,
            job_type,
            existing["recovery_policy"] || Keyword.get(opts, :recovery_policy)
          )

      case LifecyclePolicy.attempt_decision(policy, List.wrap(existing["attempt_history"])) do
        {:allowed, details} ->
          {:ok, Map.put(details, "policy", policy)}

        {:exhausted, details} when job_type in ["service", "system"] ->
          {:ok,
           details
           |> Map.put("policy", policy)
           |> Map.put("continuous", true)
           |> Map.put("delay_ms", policy["max_delay_ms"] || policy["delay_ms"] || 0)}

        {:exhausted, details} ->
          {:exhausted, Map.put(details, "policy", policy)}
      end
    end
  end

  defp fail_exhausted_attempt(existing, manifest, opts, lease, details) do
    reason = details["reason"] || "job restart attempts exhausted"

    updates = %{
      "status" => "failed",
      "restart_reason" => reason,
      "restart_budget" => details,
      "recovery_mode" => "clean_restart",
      "lease" => lease,
      "lease_epoch" => lease["epoch"],
      "lease_owner" => nil,
      "result" => %{
        "agent_id" => "job_runner",
        "reason" => reason,
        "status_reason" => reason,
        "error" => %{
          "code" => "runtime.job_attempts.exhausted",
          "message" => reason,
          "retryable" => false
        }
      }
    }

    defaults = job_defaults(manifest, Keyword.get(opts, :bundle_ref), lease, opts)

    case RedisStore.persist_terminal_job(existing["job_id"], updates, defaults) do
      {:ok, _job} -> {:exhausted, reason}
      {:error, persist_reason} -> {:error, {:attempt_exhaustion_persist_failed, persist_reason}}
    end
  end

  defp pause_for_approval(existing, lease, reason) do
    updates = %{
      "status" => "paused",
      "restart_reason" => reason,
      "recovery_mode" => "clean_restart",
      "recovery_status" => "paused_for_review",
      "recovery_reason" => reason,
      "recovery_requires_review" => true,
      "recovery" => %{
        "mode" => "clean_restart",
        "status" => "paused_for_review",
        "reason" => reason,
        "requires_review" => true,
        "can_resume" => true,
        "updated_at" => Runtime.timestamp()
      },
      "lease" => lease,
      "lease_epoch" => lease["epoch"],
      "lease_owner" => nil
    }

    case RedisStore.persist_terminal_job(existing["job_id"], updates, existing) do
      {:ok, _job} -> {:paused, reason}
      {:error, persist_reason} -> {:error, {:restart_pause_persist_failed, persist_reason}}
    end
  end

  defp attempt_not_before(%{"delay_ms" => delay_ms})
       when is_integer(delay_ms) and delay_ms > 0,
       do: LifecyclePolicy.iso_after(delay_ms)

  defp attempt_not_before(_budget), do: nil

  defp integer_value(value, _default) when is_integer(value), do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp maybe_put_lease(map, nil), do: map

  defp maybe_put_lease(map, lease) do
    map
    |> Map.put("lease", lease)
    |> Map.put("lease_epoch", lease["epoch"])
    |> Map.put("lease_owner", lease["owner_id"])
  end

  defp reliability_from(manifest, opts) do
    requested =
      Keyword.get(opts, :requested_recovery_policy) ||
        Map.get(manifest.policies, "recovery_mode", "auto")

    effective =
      Keyword.get(opts, :recovery_policy) ||
        if(requested == "auto", do: "local_restart", else: requested)

    defaults = %{
      "mode" => "single_node",
      "requested_recovery_policy" => requested,
      "effective_recovery_policy" => effective,
      "reliability_degraded" => false,
      "degraded" => false,
      "reason" => "fallback runtime persistence",
      "observed_nodes" => [to_string(Node.self())],
      "observed_at" => Runtime.timestamp()
    }

    reliability =
      case Keyword.get(opts, :reliability, %{}) do
        value when is_map(value) -> value
        _value -> %{}
      end

    Map.merge(defaults, reliability)
  end

  defp scheduler_plan(manifest, opts) do
    Keyword.get(opts, :scheduler_plan) ||
      %{
        "status" => "unknown",
        "job_type" => manifest.type || "batch",
        "strategy" => "unknown",
        "placements" => []
      }
  end

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
