defmodule MirrorNeuron.Runtime.DeploymentController.AgentRollout do
  @moduledoc "Canary and rolling replacement of agents within an existing job."

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.DeploymentController.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.ServiceRegistry

  def agent_level_update(
        deployment,
        source_job_id,
        %JobBundle{manifest: manifest} = bundle,
        scheduler_plan,
        version,
        policy,
        changed_agent_ids,
        _opts
      ) do
    deployment_key = deployment["deployment_key"]
    deployment_id = Records.deployment_id(deployment_key)
    canary_count = canary_count(policy, changed_agent_ids)
    canary? = canary_count > 0

    first_batch =
      if canary?,
        do: Enum.take(changed_agent_ids, canary_count),
        else: Enum.take(changed_agent_ids, max(policy["max_parallel"], 1))

    remaining = changed_agent_ids -- first_batch
    role = if canary?, do: "canary", else: "primary"

    running_deployment =
      deployment
      |> Map.merge(%{
        "deployment_id" => deployment_id,
        "status" => "running",
        "description" => "agent-level deployment running",
        "strategy" => policy["strategy"],
        "policy" => policy,
        "source_job_id" => source_job_id,
        "target_job_id" => source_job_id,
        "current_job_id" => source_job_id,
        "target_version" => version,
        "target_manifest" => Manifest.to_map(manifest),
        "target_scheduler" => scheduler_plan,
        "changed_agent_ids" => changed_agent_ids,
        "remaining_agent_ids" => remaining,
        "canary_agent_ids" => if(canary?, do: first_batch, else: []),
        "mode" => "agent_level",
        "events" =>
          Records.append_deployment_event(deployment, "deployment_started", %{
            "version" => version,
            "changed_agent_ids" => changed_agent_ids
          })
      })

    with {:ok, persisted} <- Records.persist_deployment(running_deployment),
         {:ok, _replace_result} <-
           Runtime.deploy_agents(
             source_job_id,
             first_batch,
             manifest,
             scheduler_plan,
             Records.deployment_context(deployment_id, deployment_key, version, role, policy, %{
               "phase" => if(canary?, do: "canary", else: "rolling")
             })
           ),
         {:ok, job} <- RedisStore.fetch_job(source_job_id),
         {:ok, version_record} <-
           Records.persist_version(deployment_key, version, manifest, job, bundle, stable: false) do
      cond do
        canary? and policy["auto_promote"] != true ->
          awaiting =
            persisted
            |> Map.merge(%{
              "status" => "awaiting_promotion",
              "description" => "canary is running and awaiting promotion",
              "remaining_agent_ids" => remaining,
              "events" =>
                Records.append_deployment_event(persisted, "deployment_canary_ready", %{
                  "version" => version,
                  "canary_agent_ids" => first_batch
                })
            })

          with {:ok, next_deployment} <- Records.persist_deployment(awaiting) do
            {:ok,
             %{
               "deployment" => next_deployment,
               "version" => version_record,
               "job_id" => source_job_id,
               "status" => "awaiting_promotion"
             }}
          end

        true ->
          finish_agent_rollout(
            persisted,
            version_record,
            manifest,
            scheduler_plan,
            first_batch,
            remaining,
            policy
          )
      end
    end
  end

  def finish_agent_rollout(
        deployment,
        version_record,
        manifest,
        scheduler_plan,
        _completed,
        remaining,
        policy
      ) do
    deployment_key = deployment["deployment_key"]
    deployment_id = deployment["deployment_id"]
    version = deployment["target_version"]
    job_id = deployment["target_job_id"]

    result =
      remaining
      |> Enum.chunk_every(max(policy["max_parallel"], 1))
      |> Enum.reduce_while(:ok, fn batch, :ok ->
        context =
          Records.deployment_context(deployment_id, deployment_key, version, "primary", policy, %{
            "phase" => "rolling"
          })

        case Runtime.deploy_agents(job_id, batch, manifest, scheduler_plan, context) do
          {:ok, _result} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- result,
         {:ok, _services} <- ServiceRegistry.promote_deployment(deployment_key, version),
         {:ok, promoted_version} <-
           Records.persist_version_record(Map.put(version_record, "stable", true)),
         {:ok, job} <- RedisStore.fetch_job(job_id),
         {:ok, next_deployment} <-
           Records.persist_successful_deployment(
             deployment,
             job,
             version,
             policy,
             "agent-level deployment completed"
           ) do
      {:ok,
       %{
         "deployment" => next_deployment,
         "version" => promoted_version,
         "job_id" => job_id,
         "status" => "successful"
       }}
    end
  end

  def canary_count(policy, agent_ids) do
    count = length(agent_ids)
    canary = policy["canary"] || 0

    cond do
      count == 0 -> 0
      canary > 0 -> min(canary, count)
      policy["strategy"] == "canary" -> 1
      true -> 0
    end
  end
end
