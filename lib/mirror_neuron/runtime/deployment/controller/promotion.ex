defmodule MirrorNeuron.Runtime.DeploymentController.Promotion do
  @moduledoc "Promotes staged agent and blue-green deployment versions."

  alias MirrorNeuron.Runtime.DeploymentController.AgentRollout
  alias MirrorNeuron.Runtime.DeploymentController.BlueGreen
  alias MirrorNeuron.Runtime.DeploymentPolicy
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Persistence.RedisStore

  def promote_pending(%{"mode" => "agent_level"} = deployment, _opts) do
    with {:ok, manifest} <- Manifest.load(deployment["target_manifest"] || %{}),
         scheduler_plan when is_map(scheduler_plan) <- deployment["target_scheduler"],
         {:ok, version_record} <-
           RedisStore.fetch_job_version(
             deployment["deployment_key"],
             deployment["target_version"]
           ) do
      remaining = deployment["remaining_agent_ids"] || []
      policy = deployment["policy"] || DeploymentPolicy.normalize(%{})

      AgentRollout.finish_agent_rollout(
        deployment,
        version_record,
        manifest,
        scheduler_plan,
        deployment["canary_agent_ids"] || [],
        remaining,
        policy
      )
    else
      nil -> {:error, "deployment target scheduler is missing"}
      other -> other
    end
  end

  def promote_pending(%{"mode" => "blue_green"} = deployment, _opts) do
    with {:ok, version_record} <-
           RedisStore.fetch_job_version(
             deployment["deployment_key"],
             deployment["target_version"]
           ) do
      BlueGreen.promote_blue_green(deployment, version_record, deployment["policy"] || %{})
    end
  end

  def promote_pending(deployment, _opts),
    do: {:error, "deployment #{deployment["deployment_id"]} cannot be promoted"}
end
