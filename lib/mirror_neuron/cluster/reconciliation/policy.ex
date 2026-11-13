defmodule MirrorNeuron.Cluster.Reconciler.Policy do
  @moduledoc "Applies and records bounded per-agent reschedule policy."

  require Logger

  alias MirrorNeuron.Cluster.Reconciler.Jobs
  alias MirrorNeuron.Runtime.LifecyclePolicy
  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Runtime

  def ensure_reschedule_policy_allows(job, agent_ids, opts) do
    if Keyword.get(opts, :skip_reschedule_policy, false) do
      :ok
    else
      agent_ids = normalize_policy_agent_ids(agent_ids)

      Enum.reduce_while(agent_ids, :ok, fn agent_id, :ok ->
        policy = LifecyclePolicy.reschedule_policy_from_job(job, agent_id)
        history = policy_history(job, agent_id, "reschedule")

        case LifecyclePolicy.attempt_decision(policy, history) do
          {:allowed, _decision} ->
            {:cont, :ok}

          {:exhausted, exhaustion} ->
            {:halt,
             {:policy_blocked,
              "reschedule policy blocked #{agent_id}: #{Map.get(exhaustion, "reason")}"}}
        end
      end)
    end
  end

  def record_reschedule_policy_attempt(job, agent_ids, reason, opts) do
    if Options.dry_run?(opts) or Keyword.get(opts, :skip_reschedule_policy_record, false) do
      :ok
    else
      agent_ids = normalize_policy_agent_ids(agent_ids)

      next_policy_state =
        Enum.reduce(agent_ids, Map.get(job, "policy_state", %{"agents" => %{}}), fn agent_id,
                                                                                    policy_state ->
          policy = LifecyclePolicy.reschedule_policy_from_job(job, agent_id)
          history = policy_history(%{"policy_state" => policy_state}, agent_id, "reschedule")

          history =
            LifecyclePolicy.append_history(
              history,
              "reschedule",
              reason || "cluster reconciliation"
            )

          put_policy_agent_fields(policy_state, agent_id, %{
            "reschedule_history" => history,
            "reschedule_attempts" => LifecyclePolicy.active_attempt_count(policy, history),
            "last_reason" => reason,
            "next_action" => "reschedule",
            "next_eligible_at" => Runtime.timestamp(),
            "updated_at" => Runtime.timestamp()
          })
        end)

      defaults = Jobs.job_defaults(job, Runtime.timestamp())

      case Options.redis_store(opts).persist_terminal_job(
             job["job_id"],
             %{"policy_state" => next_policy_state},
             defaults
           ) do
        {:ok, _job} ->
          :ok

        {:error, persist_reason} ->
          Logger.warning(
            "failed to persist reschedule policy attempt for #{job["job_id"]}: #{inspect(persist_reason)}"
          )

          :ok
      end
    end
  end

  defp normalize_policy_agent_ids([]), do: ["__job__"]

  defp normalize_policy_agent_ids(agent_ids) do
    agent_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["__job__"]
      ids -> Enum.uniq(ids)
    end
  end

  defp policy_history(job, agent_id, kind) do
    get_in(job, ["policy_state", "agents", agent_id, "#{kind}_history"]) || []
  end

  defp put_policy_agent_fields(policy_state, agent_id, fields) do
    policy_state = Map.put_new(policy_state || %{}, "agents", %{})
    agents = Map.get(policy_state, "agents", %{})
    current = Map.get(agents, agent_id, %{})

    policy_state
    |> Map.put("agents", Map.put(agents, agent_id, Map.merge(current, fields)))
    |> Map.put("updated_at", Runtime.timestamp())
  end

  def whole_job_policy_agents(job) do
    job
    |> get_in(["scheduler", "placements"])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "agent_id"))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["__job__"]
      ids -> ids
    end
  end
end
