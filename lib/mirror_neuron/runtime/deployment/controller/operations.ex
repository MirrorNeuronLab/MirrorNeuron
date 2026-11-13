defmodule MirrorNeuron.Runtime.DeploymentController.Operations do
  @moduledoc "Public deployment operations and strategy selection."

  alias MirrorNeuron.Runtime.DeploymentController.AgentRollout
  alias MirrorNeuron.Runtime.DeploymentController.BlueGreen
  alias MirrorNeuron.Runtime.DeploymentController.Comparison
  alias MirrorNeuron.Runtime.DeploymentController.Creation
  alias MirrorNeuron.Runtime.DeploymentPolicy
  alias MirrorNeuron.Runtime.DeploymentController.Inputs
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.DeploymentController.Promotion
  alias MirrorNeuron.Runtime.DeploymentController.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.Runtime.DeploymentController.Versions

  @active_job_statuses ["pending", "running", "paused"]
  @long_running_job_types ["service", "system"]

  def deploy_manifest(input, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         {:ok, bundle} <- Inputs.apply_deployment_options(bundle, opts),
         :ok <- Inputs.preflight_bundle(bundle),
         {:ok, result} <- deploy_or_update(bundle, opts) do
      {:ok, result}
    end
  end

  def update_deployment(deployment_key, input, opts \\ []) do
    opts = Keyword.put(opts, :deployment_key, deployment_key)

    with {:ok, bundle} <- JobBundle.load(input),
         {:ok, bundle} <- Inputs.apply_deployment_options(bundle, opts),
         :ok <- Inputs.preflight_bundle(bundle),
         {:ok, current} <- RedisStore.fetch_deployment_by_key(deployment_key),
         {:ok, result} <- update_existing(current, bundle, opts) do
      {:ok, result}
    else
      {:error, "deployment " <> _} ->
        deploy_manifest(input, opts)

      other ->
        other
    end
  end

  def promote_deployment(id_or_key, opts \\ []) do
    with {:ok, deployment} <- RedisStore.fetch_deployment_ref(id_or_key),
         :ok <- ensure_status(deployment, "awaiting_promotion"),
         {:ok, result} <- Promotion.promote_pending(deployment, opts) do
      {:ok, result}
    end
  end

  def rollback_deployment(id_or_key, opts \\ []) do
    with {:ok, deployment} <- RedisStore.fetch_deployment_ref(id_or_key),
         {:ok, version} <- Versions.rollback_version(deployment, opts),
         {:ok, bundle_or_manifest} <- Versions.bundle_or_manifest_from_version(version),
         {:ok, result} <-
           update_deployment(deployment["deployment_key"], bundle_or_manifest,
             rollback_from: deployment["current_version"],
             rollback_to: version["version"],
             reason: Keyword.get(opts, :reason, "rollback")
           ) do
      {:ok, result}
    end
  end

  def pause_deployment(id_or_key, opts \\ []) do
    Records.update_deployment_status(
      id_or_key,
      "paused",
      Keyword.get(opts, :reason, "paused by operator")
    )
  end

  def resume_deployment(id_or_key, opts \\ []) do
    Records.update_deployment_status(
      id_or_key,
      "running",
      Keyword.get(opts, :reason, "resumed by operator")
    )
  end

  def fail_deployment(id_or_key, opts \\ []) do
    Records.update_deployment_status(
      id_or_key,
      "failed",
      Keyword.get(opts, :reason, "failed by operator")
    )
  end

  def get_deployment(id_or_key) do
    with {:ok, deployment} <- RedisStore.fetch_deployment_ref(id_or_key),
         {:ok, versions} <- RedisStore.list_job_versions(deployment["deployment_key"]) do
      {:ok, Map.put(deployment, "versions", versions)}
    end
  end

  def list_deployments(opts \\ []) do
    with {:ok, deployments} <- RedisStore.list_deployments() do
      {:ok, filter_deployments(deployments, opts)}
    end
  end

  defp deploy_or_update(%JobBundle{manifest: manifest} = bundle, opts) do
    deployment_key = DeploymentPolicy.deployment_key(manifest, Keyword.get(opts, :deployment_key))

    case RedisStore.fetch_deployment_by_key(deployment_key) do
      {:ok, deployment} -> update_existing(deployment, bundle, opts)
      {:error, _reason} -> Creation.create_initial_deployment(deployment_key, bundle, opts)
    end
  end

  defp update_existing(deployment, %JobBundle{manifest: manifest} = bundle, opts) do
    deployment_key = deployment["deployment_key"]
    version = Versions.next_version(deployment_key)
    policy = DeploymentPolicy.normalize(manifest, Keyword.get(opts, :update_policy, %{}))
    source_job_id = deployment["stable_job_id"] || deployment["current_job_id"]
    strategy = Keyword.get(opts, :strategy) || policy["strategy"]
    policy = Map.put(policy, "strategy", to_string(strategy))

    with {:ok, source_job} <- RedisStore.fetch_job(source_job_id),
         {:ok, source_manifest} <- Manifest.load(source_job["manifest"] || %{}),
         {:ok, scheduler_plan} <- Scheduler.plan(manifest, opts),
         {:ok, result} <-
           route_update(
             deployment,
             source_job,
             source_manifest,
             bundle,
             scheduler_plan,
             version,
             policy,
             opts
           ) do
      {:ok, result}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_update(
         deployment,
         source_job,
         source_manifest,
         %JobBundle{manifest: target_manifest} = bundle,
         scheduler_plan,
         version,
         policy,
         opts
       ) do
    source_job_id = source_job["job_id"]
    job_type = source_job["job_type"] || get_in(source_job, ["scheduler", "job_type"]) || "batch"

    cond do
      job_type not in @long_running_job_types ->
        Creation.create_batch_version(deployment, bundle, scheduler_plan, version, policy, opts)

      not Comparison.same_topology?(source_manifest, target_manifest) ->
        BlueGreen.blue_green_update(deployment, bundle, scheduler_plan, version, policy, opts)

      source_job["status"] not in @active_job_statuses ->
        BlueGreen.blue_green_update(deployment, bundle, scheduler_plan, version, policy, opts)

      true ->
        changed_source_ids = Comparison.changed_source_agent_ids(source_manifest, target_manifest)

        if changed_source_ids == [] do
          Creation.mark_noop_version(deployment, bundle, scheduler_plan, version, policy)
        else
          AgentRollout.agent_level_update(
            deployment,
            source_job_id,
            bundle,
            scheduler_plan,
            version,
            policy,
            Comparison.runtime_agent_ids(scheduler_plan, changed_source_ids),
            opts
          )
        end
    end
  end

  defp ensure_status(%{"status" => status}, expected) when status == expected, do: :ok

  defp ensure_status(%{"status" => status}, expected),
    do: {:error, "deployment is #{status}, expected #{expected}"}

  defp filter_deployments(deployments, opts) do
    key = Keyword.get(opts, :deployment_key)
    status = Keyword.get(opts, :status)

    Enum.filter(deployments, fn deployment ->
      (is_nil(key) or deployment["deployment_key"] == key) and
        (is_nil(status) or deployment["status"] == status)
    end)
  end
end
