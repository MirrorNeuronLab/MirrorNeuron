defmodule MirrorNeuron.Runtime.DeploymentController.BlueGreen do
  @moduledoc "Replacement jobs, service promotion and source-job retirement."

  alias MirrorNeuron.Runtime.DeploymentController.AgentRollout
  alias MirrorNeuron.Runtime.DeploymentController.Health
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.DeploymentController.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.ServiceRegistry

  def blue_green_update(
        deployment,
        %JobBundle{manifest: manifest} = bundle,
        scheduler_plan,
        version,
        policy,
        opts
      ) do
    deployment_key = deployment["deployment_key"]
    deployment_id = Records.deployment_id(deployment_key)
    canary? = AgentRollout.canary_count(policy, [manifest.graph_id]) > 0
    role = if canary?, do: "candidate", else: "primary"

    context =
      Records.deployment_context(deployment_id, deployment_key, version, role, policy, %{
        "phase" => if(canary?, do: "canary", else: "blue_green")
      })

    with {:ok, job_id, _pid} <-
           Runtime.start_job(
             manifest,
             opts
             |> Keyword.put(:job_bundle, bundle)
             |> Keyword.put(:scheduler_plan, scheduler_plan)
             |> Keyword.put(:deployment_context, context)
           ),
         {:ok, job} <- Health.wait_for_started_job(job_id, policy),
         {:ok, version_record} <-
           Records.persist_version(deployment_key, version, manifest, job, bundle, stable: false) do
      next =
        deployment
        |> Map.merge(%{
          "deployment_id" => deployment_id,
          "status" => if(canary?, do: "awaiting_promotion", else: "running"),
          "description" =>
            if(canary?,
              do: "blue/green candidate is running and awaiting promotion",
              else: "blue/green deployment running"
            ),
          "strategy" => "blue-green",
          "policy" => policy,
          "source_job_id" => deployment["stable_job_id"] || deployment["current_job_id"],
          "target_job_id" => job_id,
          "current_job_id" => if(canary?, do: deployment["current_job_id"], else: job_id),
          "target_version" => version,
          "target_manifest" => Manifest.to_map(manifest),
          "target_scheduler" => scheduler_plan,
          "mode" => "blue_green",
          "events" =>
            Records.append_deployment_event(deployment, "deployment_started", %{
              "version" => version,
              "target_job_id" => job_id,
              "mode" => "blue_green"
            })
        })

      with {:ok, persisted} <- Records.persist_deployment(next) do
        if canary? do
          {:ok,
           %{
             "deployment" => persisted,
             "version" => version_record,
             "job_id" => job_id,
             "status" => "awaiting_promotion"
           }}
        else
          promote_blue_green(persisted, version_record, policy)
        end
      end
    end
  end

  def promote_blue_green(deployment, version_record, policy) do
    deployment_key = deployment["deployment_key"]
    version = deployment["target_version"]
    target_job_id = deployment["target_job_id"]
    source_job_id = deployment["source_job_id"]

    with {:ok, _services} <- ServiceRegistry.promote_deployment(deployment_key, version),
         {:ok, promoted_version} <-
           Records.persist_version_record(Map.put(version_record, "stable", true)),
         {:ok, target_job} <- RedisStore.fetch_job(target_job_id),
         _cancel <- maybe_cancel_source_job(source_job_id, target_job_id),
         {:ok, next_deployment} <-
           Records.persist_successful_deployment(
             deployment,
             target_job,
             version,
             policy,
             "blue/green deployment promoted"
           ) do
      {:ok,
       %{
         "deployment" => next_deployment,
         "version" => promoted_version,
         "job_id" => target_job_id,
         "status" => "successful"
       }}
    end
  end

  defp maybe_cancel_source_job(nil, _target_job_id), do: :ok

  defp maybe_cancel_source_job(source_job_id, source_job_id), do: :ok

  defp maybe_cancel_source_job(source_job_id, _target_job_id) do
    case MirrorNeuron.cancel(source_job_id) do
      {:ok, _status} -> :ok
      _other -> :ok
    end
  end
end
