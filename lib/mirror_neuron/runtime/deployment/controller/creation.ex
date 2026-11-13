defmodule MirrorNeuron.Runtime.DeploymentController.Creation do
  @moduledoc "Initial deployments, batch reruns and versions without runtime changes."

  alias MirrorNeuron.Runtime.DeploymentPolicy
  alias MirrorNeuron.Runtime.DeploymentController.Health
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Runtime.DeploymentController.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.DeploymentController.Versions

  def create_initial_deployment(deployment_key, %JobBundle{manifest: manifest} = bundle, opts) do
    version = Versions.next_version(deployment_key)
    deployment_id = Records.deployment_id(deployment_key)
    policy = DeploymentPolicy.normalize(manifest, Keyword.get(opts, :update_policy, %{}))

    context =
      Records.deployment_context(deployment_id, deployment_key, version, "primary", policy, %{
        "phase" => "initial"
      })

    with {:ok, job_id, _pid} <-
           Runtime.start_job(
             manifest,
             opts
             |> Keyword.put(:job_bundle, bundle)
             |> Keyword.put(:deployment_context, context)
           ),
         {:ok, job} <- Health.wait_for_started_job(job_id, policy),
         {:ok, version_record} <-
           Records.persist_version(deployment_key, version, manifest, job, bundle, stable: true),
         {:ok, deployment} <-
           Records.persist_deployment(%{
             "deployment_id" => deployment_id,
             "deployment_key" => deployment_key,
             "status" => "successful",
             "description" => "initial deployment completed",
             "strategy" => policy["strategy"],
             "policy" => policy,
             "current_job_id" => job_id,
             "stable_job_id" => job_id,
             "current_version" => version,
             "stable_version" => version,
             "target_version" => version,
             "health" => Records.health_summary(job),
             "events" => [
               Records.deployment_event("deployment_created", %{
                 "job_id" => job_id,
                 "version" => version
               })
             ]
           }) do
      {:ok,
       %{
         "deployment" => deployment,
         "version" => version_record,
         "job_id" => job_id,
         "status" => deployment["status"]
       }}
    end
  end

  def create_batch_version(
        deployment,
        %JobBundle{manifest: manifest} = bundle,
        scheduler_plan,
        version,
        policy,
        opts
      ) do
    deployment_key = deployment["deployment_key"]
    deployment_id = Records.deployment_id(deployment_key)

    context =
      Records.deployment_context(deployment_id, deployment_key, version, "primary", policy, %{
        "phase" => "rerun"
      })

    with {:ok, job_id, _pid} <-
           Runtime.start_job(
             manifest,
             opts
             |> Keyword.put(:job_bundle, bundle)
             |> Keyword.put(:scheduler_plan, scheduler_plan)
             |> Keyword.put(:deployment_context, context)
           ),
         {:ok, job} <- RedisStore.fetch_job(job_id),
         {:ok, version_record} <-
           Records.persist_version(deployment_key, version, manifest, job, bundle, stable: false),
         {:ok, next_deployment} <-
           Records.persist_deployment(
             deployment
             |> Map.merge(%{
               "deployment_id" => deployment_id,
               "status" => "version_recorded",
               "description" => "batch/sysbatch version recorded as rerun",
               "current_job_id" => job_id,
               "current_version" => version,
               "target_version" => version,
               "policy" => policy,
               "events" =>
                 Records.append_deployment_event(deployment, "deployment_version_recorded", %{
                   "job_id" => job_id,
                   "version" => version
                 })
             })
           ) do
      {:ok, %{"deployment" => next_deployment, "version" => version_record, "job_id" => job_id}}
    end
  end

  def mark_noop_version(
        deployment,
        %JobBundle{manifest: manifest} = bundle,
        _scheduler_plan,
        version,
        policy
      ) do
    deployment_key = deployment["deployment_key"]
    job_id = deployment["stable_job_id"] || deployment["current_job_id"]

    with {:ok, job} <- RedisStore.fetch_job(job_id),
         {:ok, version_record} <-
           Records.persist_version(deployment_key, version, manifest, job, bundle, stable: true),
         {:ok, next_deployment} <-
           Records.persist_deployment(
             deployment
             |> Map.merge(%{
               "status" => "successful",
               "description" => "deployment contained no runtime changes",
               "current_version" => version,
               "stable_version" => version,
               "target_version" => version,
               "policy" => policy,
               "events" =>
                 Records.append_deployment_event(deployment, "deployment_noop", %{
                   "version" => version
                 })
             })
           ) do
      {:ok, %{"deployment" => next_deployment, "version" => version_record, "job_id" => job_id}}
    end
  end
end
