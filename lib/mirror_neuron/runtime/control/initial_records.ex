defmodule MirrorNeuron.Runtime.InitialRecords do
  @moduledoc "Initial run snapshots, startup failures and reliability observations."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.LifecyclePolicy
  alias MirrorNeuron.Runtime.NodeAdmission

  def persist_startup_failure(
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
        "submitted_at" => Runtime.timestamp()
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
          timestamp: Runtime.timestamp()
        })

        ok

      other ->
        other
    end
  end

  def persist_initial_job(
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
        "delivery_version" => 2,
        "job_data_dir" => Keyword.get(opts, :job_data_dir),
        "job_data_access" => Keyword.get(opts, :job_data_access),
        "data_generation" => Keyword.get(opts, :data_generation),
        "graph_id" => manifest.graph_id,
        "job_name" => manifest.job_name,
        "type" => manifest.type,
        "required_context_engine" => required_context_engine(manifest),
        "status" => Keyword.get(opts, :admission_status, "pending"),
        "admission" =>
          Keyword.get(opts, :admission, %{
            "owner_node" => NodeAdmission.node_name(),
            "state" => "queued",
            "authority_epoch" => NodeAdmission.authority_epoch()
          }),
        "submitted_at" => Runtime.timestamp(),
        "updated_at" => Runtime.timestamp(),
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

  def required_context_engine(manifest), do: Map.get(manifest, :required_context_engine, false)

  def reliability_map(reliability) do
    Map.take(reliability, [
      "mode",
      "effective_recovery_policy",
      "degraded",
      "reason",
      "observed_nodes",
      "observed_at"
    ])
  end

  def policy_fields(manifest, reliability, scheduler_plan) do
    policies =
      LifecyclePolicy.normalize(
        manifest,
        scheduler_plan["job_type"],
        reliability["effective_recovery_policy"]
      )

    Map.put(policies, "policy_state", %{"agents" => %{}})
  end

  def publish_reliability_events(job_id, reliability) do
    EventBus.publish(job_id, %{
      type: :reliability_strategy_resolved,
      requested_recovery_policy: reliability["requested_recovery_policy"],
      effective_recovery_policy: reliability["effective_recovery_policy"],
      mode: reliability["mode"],
      degraded: reliability["reliability_degraded"],
      reason: reliability["reason"],
      observed_nodes: reliability["observed_nodes"],
      timestamp: Runtime.timestamp()
    })

    if reliability["reliability_degraded"] do
      EventBus.publish(job_id, %{
        type: :job_reliability_degraded,
        mode: reliability["mode"],
        reason: reliability["reason"],
        observed_nodes: reliability["observed_nodes"],
        timestamp: Runtime.timestamp()
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
