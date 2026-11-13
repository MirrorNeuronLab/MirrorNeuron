defmodule MirrorNeuron.Runtime.DeploymentController.Records do
  @moduledoc "Deployment and version persistence, context and bounded lifecycle history."

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  def persist_successful_deployment(deployment, job, version, policy, description) do
    persist_deployment(
      deployment
      |> Map.merge(%{
        "status" => "successful",
        "description" => description,
        "current_job_id" => job["job_id"],
        "stable_job_id" => job["job_id"],
        "current_version" => version,
        "stable_version" => version,
        "target_version" => version,
        "policy" => policy,
        "health" => health_summary(job),
        "remaining_agent_ids" => [],
        "events" =>
          append_deployment_event(deployment, "deployment_successful", %{
            "job_id" => job["job_id"],
            "version" => version
          })
      })
    )
  end

  def update_deployment_status(id_or_key, status, reason) do
    with {:ok, deployment} <- RedisStore.fetch_deployment_ref(id_or_key),
         {:ok, next_deployment} <-
           persist_deployment(
             deployment
             |> Map.merge(%{
               "status" => status,
               "description" => reason,
               "events" =>
                 append_deployment_event(deployment, "deployment_#{status}", %{"reason" => reason})
             })
           ) do
      {:ok, next_deployment}
    end
  end

  def persist_deployment(deployment) do
    RedisStore.persist_deployment(deployment["deployment_id"], deployment)
  end

  def persist_version(deployment_key, version, manifest, job, bundle, opts) do
    persist_version_record(%{
      "deployment_key" => deployment_key,
      "version" => to_string(version),
      "job_id" => job["job_id"],
      "manifest" => Manifest.to_map(manifest),
      "manifest_ref" => job["manifest_ref"] || Runtime.bundle_ref(manifest, bundle),
      "scheduler" => job["scheduler"],
      "submitted_at" => job["submitted_at"] || Runtime.timestamp(),
      "stable" => Keyword.get(opts, :stable, false),
      "tag" => Keyword.get(opts, :tag)
    })
  end

  def persist_version_record(version_record) do
    RedisStore.persist_job_version(
      version_record["deployment_key"],
      version_record["version"],
      version_record
    )
  end

  def deployment_context(deployment_id, deployment_key, version, role, policy, extra) do
    %{
      "deployment_id" => deployment_id,
      "deployment_key" => deployment_key,
      "deployment_version" => to_string(version),
      "deployment_role" => role,
      "deployment_policy" => policy
    }
    |> Map.merge(extra)
  end

  def deployment_id(deployment_key) do
    safe_key =
      deployment_key
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
      |> String.trim("-")

    "dep_#{safe_key}_#{System.unique_integer([:positive])}"
  end

  def health_summary(job) do
    %{
      "job_status" => job["status"],
      "updated_at" => job["updated_at"] || Runtime.timestamp()
    }
  end

  def deployment_event(type, fields) do
    fields
    |> Map.put("type", type)
    |> Map.put("timestamp", Runtime.timestamp())
  end

  def append_deployment_event(deployment, type, fields) do
    deployment
    |> Map.get("events", [])
    |> List.wrap()
    |> Kernel.++([deployment_event(type, fields)])
    |> Enum.take(-100)
  end
end
