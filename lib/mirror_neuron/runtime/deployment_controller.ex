defmodule MirrorNeuron.Runtime.DeploymentController do
  @moduledoc false

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.{JobBundle, Manifest, Scheduler, ServiceRegistry}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.DeploymentPolicy

  @active_job_statuses ["pending", "running", "paused"]
  @long_running_job_types ["service", "system"]

  def deploy_manifest(input, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         {:ok, bundle} <- apply_deployment_options(bundle, opts),
         :ok <- preflight_bundle(bundle),
         {:ok, result} <- deploy_or_update(bundle, opts) do
      {:ok, result}
    end
  end

  def update_deployment(deployment_key, input, opts \\ []) do
    opts = Keyword.put(opts, :deployment_key, deployment_key)

    with {:ok, bundle} <- JobBundle.load(input),
         {:ok, bundle} <- apply_deployment_options(bundle, opts),
         :ok <- preflight_bundle(bundle),
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
         {:ok, result} <- promote_pending(deployment, opts) do
      {:ok, result}
    end
  end

  def rollback_deployment(id_or_key, opts \\ []) do
    with {:ok, deployment} <- RedisStore.fetch_deployment_ref(id_or_key),
         {:ok, version} <- rollback_version(deployment, opts),
         {:ok, bundle_or_manifest} <- bundle_or_manifest_from_version(version),
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
    update_deployment_status(
      id_or_key,
      "paused",
      Keyword.get(opts, :reason, "paused by operator")
    )
  end

  def resume_deployment(id_or_key, opts \\ []) do
    update_deployment_status(
      id_or_key,
      "running",
      Keyword.get(opts, :reason, "resumed by operator")
    )
  end

  def fail_deployment(id_or_key, opts \\ []) do
    update_deployment_status(
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
      {:error, _reason} -> create_initial_deployment(deployment_key, bundle, opts)
    end
  end

  defp create_initial_deployment(deployment_key, %JobBundle{manifest: manifest} = bundle, opts) do
    version = next_version(deployment_key)
    deployment_id = deployment_id(deployment_key)
    policy = DeploymentPolicy.normalize(manifest, Keyword.get(opts, :update_policy, %{}))

    context =
      deployment_context(deployment_id, deployment_key, version, "primary", policy, %{
        "phase" => "initial"
      })

    with {:ok, job_id, _pid} <-
           Runtime.start_job(
             manifest,
             opts
             |> Keyword.put(:job_bundle, bundle)
             |> Keyword.put(:deployment_context, context)
           ),
         {:ok, job} <- wait_for_started_job(job_id, policy),
         {:ok, version_record} <-
           persist_version(deployment_key, version, manifest, job, bundle, stable: true),
         {:ok, deployment} <-
           persist_deployment(%{
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
             "health" => health_summary(job),
             "events" => [
               deployment_event("deployment_created", %{
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

  defp update_existing(deployment, %JobBundle{manifest: manifest} = bundle, opts) do
    deployment_key = deployment["deployment_key"]
    version = next_version(deployment_key)
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
        create_batch_version(deployment, bundle, scheduler_plan, version, policy, opts)

      not same_topology?(source_manifest, target_manifest) ->
        blue_green_update(deployment, bundle, scheduler_plan, version, policy, opts)

      source_job["status"] not in @active_job_statuses ->
        blue_green_update(deployment, bundle, scheduler_plan, version, policy, opts)

      true ->
        changed_source_ids = changed_source_agent_ids(source_manifest, target_manifest)

        if changed_source_ids == [] do
          mark_noop_version(deployment, bundle, scheduler_plan, version, policy)
        else
          agent_level_update(
            deployment,
            source_job_id,
            bundle,
            scheduler_plan,
            version,
            policy,
            runtime_agent_ids(scheduler_plan, changed_source_ids),
            opts
          )
        end
    end
  end

  defp create_batch_version(
         deployment,
         %JobBundle{manifest: manifest} = bundle,
         scheduler_plan,
         version,
         policy,
         opts
       ) do
    deployment_key = deployment["deployment_key"]
    deployment_id = deployment_id(deployment_key)

    context =
      deployment_context(deployment_id, deployment_key, version, "primary", policy, %{
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
           persist_version(deployment_key, version, manifest, job, bundle, stable: false),
         {:ok, next_deployment} <-
           persist_deployment(
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
                 append_deployment_event(deployment, "deployment_version_recorded", %{
                   "job_id" => job_id,
                   "version" => version
                 })
             })
           ) do
      {:ok, %{"deployment" => next_deployment, "version" => version_record, "job_id" => job_id}}
    end
  end

  defp agent_level_update(
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
    deployment_id = deployment_id(deployment_key)
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
          append_deployment_event(deployment, "deployment_started", %{
            "version" => version,
            "changed_agent_ids" => changed_agent_ids
          })
      })

    with {:ok, persisted} <- persist_deployment(running_deployment),
         {:ok, _replace_result} <-
           Runtime.deploy_agents(
             source_job_id,
             first_batch,
             manifest,
             scheduler_plan,
             deployment_context(deployment_id, deployment_key, version, role, policy, %{
               "phase" => if(canary?, do: "canary", else: "rolling")
             })
           ),
         {:ok, job} <- RedisStore.fetch_job(source_job_id),
         {:ok, version_record} <-
           persist_version(deployment_key, version, manifest, job, bundle, stable: false) do
      cond do
        canary? and policy["auto_promote"] != true ->
          awaiting =
            persisted
            |> Map.merge(%{
              "status" => "awaiting_promotion",
              "description" => "canary is running and awaiting promotion",
              "remaining_agent_ids" => remaining,
              "events" =>
                append_deployment_event(persisted, "deployment_canary_ready", %{
                  "version" => version,
                  "canary_agent_ids" => first_batch
                })
            })

          with {:ok, next_deployment} <- persist_deployment(awaiting) do
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

  defp finish_agent_rollout(
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
          deployment_context(deployment_id, deployment_key, version, "primary", policy, %{
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
           persist_version_record(Map.put(version_record, "stable", true)),
         {:ok, job} <- RedisStore.fetch_job(job_id),
         {:ok, next_deployment} <-
           persist_successful_deployment(
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

  defp blue_green_update(
         deployment,
         %JobBundle{manifest: manifest} = bundle,
         scheduler_plan,
         version,
         policy,
         opts
       ) do
    deployment_key = deployment["deployment_key"]
    deployment_id = deployment_id(deployment_key)
    canary? = canary_count(policy, [manifest.graph_id]) > 0
    role = if canary?, do: "candidate", else: "primary"

    context =
      deployment_context(deployment_id, deployment_key, version, role, policy, %{
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
         {:ok, job} <- wait_for_started_job(job_id, policy),
         {:ok, version_record} <-
           persist_version(deployment_key, version, manifest, job, bundle, stable: false) do
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
            append_deployment_event(deployment, "deployment_started", %{
              "version" => version,
              "target_job_id" => job_id,
              "mode" => "blue_green"
            })
        })

      with {:ok, persisted} <- persist_deployment(next) do
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

  defp mark_noop_version(
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
           persist_version(deployment_key, version, manifest, job, bundle, stable: true),
         {:ok, next_deployment} <-
           persist_deployment(
             deployment
             |> Map.merge(%{
               "status" => "successful",
               "description" => "deployment contained no runtime changes",
               "current_version" => version,
               "stable_version" => version,
               "target_version" => version,
               "policy" => policy,
               "events" =>
                 append_deployment_event(deployment, "deployment_noop", %{
                   "version" => version
                 })
             })
           ) do
      {:ok, %{"deployment" => next_deployment, "version" => version_record, "job_id" => job_id}}
    end
  end

  defp promote_pending(%{"mode" => "agent_level"} = deployment, _opts) do
    with {:ok, manifest} <- Manifest.load(deployment["target_manifest"] || %{}),
         scheduler_plan when is_map(scheduler_plan) <- deployment["target_scheduler"],
         {:ok, version_record} <-
           RedisStore.fetch_job_version(
             deployment["deployment_key"],
             deployment["target_version"]
           ) do
      remaining = deployment["remaining_agent_ids"] || []
      policy = deployment["policy"] || DeploymentPolicy.normalize(%{})

      finish_agent_rollout(
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

  defp promote_pending(%{"mode" => "blue_green"} = deployment, _opts) do
    with {:ok, version_record} <-
           RedisStore.fetch_job_version(
             deployment["deployment_key"],
             deployment["target_version"]
           ) do
      promote_blue_green(deployment, version_record, deployment["policy"] || %{})
    end
  end

  defp promote_pending(deployment, _opts),
    do: {:error, "deployment #{deployment["deployment_id"]} cannot be promoted"}

  defp promote_blue_green(deployment, version_record, policy) do
    deployment_key = deployment["deployment_key"]
    version = deployment["target_version"]
    target_job_id = deployment["target_job_id"]
    source_job_id = deployment["source_job_id"]

    with {:ok, _services} <- ServiceRegistry.promote_deployment(deployment_key, version),
         {:ok, promoted_version} <-
           persist_version_record(Map.put(version_record, "stable", true)),
         {:ok, target_job} <- RedisStore.fetch_job(target_job_id),
         _cancel <- maybe_cancel_source_job(source_job_id, target_job_id),
         {:ok, next_deployment} <-
           persist_successful_deployment(
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

  defp persist_successful_deployment(deployment, job, version, policy, description) do
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

  defp update_deployment_status(id_or_key, status, reason) do
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

  defp persist_deployment(deployment) do
    RedisStore.persist_deployment(deployment["deployment_id"], deployment)
  end

  defp persist_version(deployment_key, version, manifest, job, bundle, opts) do
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

  defp persist_version_record(version_record) do
    RedisStore.persist_job_version(
      version_record["deployment_key"],
      version_record["version"],
      version_record
    )
  end

  defp deployment_context(deployment_id, deployment_key, version, role, policy, extra) do
    %{
      "deployment_id" => deployment_id,
      "deployment_key" => deployment_key,
      "deployment_version" => to_string(version),
      "deployment_role" => role,
      "deployment_policy" => policy
    }
    |> Map.merge(extra)
  end

  defp apply_deployment_options(%JobBundle{manifest: manifest} = bundle, opts) do
    deployment_key = Keyword.get(opts, :deployment_key)
    update_policy = Keyword.get(opts, :update_policy, %{})

    deployment =
      (manifest.deployment || %{})
      |> maybe_put_deployment_key(deployment_key)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    policies =
      manifest.policies || %{}

    policies =
      if map_size(update_policy) > 0 do
        Map.put(policies, "update", Map.merge(Map.get(policies, "update", %{}), update_policy))
      else
        policies
      end

    {:ok, %{bundle | manifest: %{manifest | deployment: deployment, policies: policies}}}
  end

  defp preflight_bundle(bundle) do
    with :ok <- MirrorNeuron.ServicePreflight.run(bundle),
         :ok <- MirrorNeuron.BlueprintValidation.run_input_validation(bundle),
         :ok <- MirrorNeuron.BlueprintValidation.check_requirements(bundle.manifest) do
      :ok
    end
  end

  defp maybe_put_deployment_key(deployment, nil), do: deployment
  defp maybe_put_deployment_key(deployment, ""), do: deployment
  defp maybe_put_deployment_key(deployment, key), do: Map.put(deployment, "key", key)

  defp wait_for_started_job(job_id, policy) do
    timeout_ms = max(policy["healthy_deadline_ms"] || 0, 1_000)
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_started_job(job_id, started_at, timeout_ms)
  end

  defp do_wait_for_started_job(job_id, started_at, timeout_ms) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["running", "completed"] ->
        {:ok, job}

      {:ok, %{"status" => status} = job} when status in ["failed", "cancelled"] ->
        {:error, "deployment job #{job_id} reached #{status}: #{inspect(job["result"])}"}

      {:ok, _job} ->
        if System.monotonic_time(:millisecond) - started_at > timeout_ms do
          RedisStore.fetch_job(job_id)
        else
          Process.sleep(100)
          do_wait_for_started_job(job_id, started_at, timeout_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rollback_version(deployment, opts) do
    deployment_key = deployment["deployment_key"]
    requested = Keyword.get(opts, :version) || Keyword.get(opts, :tag)

    with {:ok, versions} <- RedisStore.list_job_versions(deployment_key) do
      version =
        cond do
          is_nil(requested) ->
            versions
            |> Enum.filter(&(&1["stable"] == true))
            |> Enum.reject(&(&1["version"] == deployment["current_version"]))
            |> List.last()

          Keyword.has_key?(opts, :tag) ->
            Enum.find(versions, &(&1["tag"] == requested))

          true ->
            Enum.find(versions, &(to_string(&1["version"]) == to_string(requested)))
        end

      case version do
        nil -> {:error, "no rollback target found for deployment #{deployment_key}"}
        record -> {:ok, record}
      end
    end
  end

  defp bundle_or_manifest_from_version(%{
         "manifest_ref" => %{"bundle_fingerprint" => fingerprint}
       })
       when is_binary(fingerprint) and fingerprint != "" do
    case Archive.load(fingerprint) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, _reason} = error -> error
    end
  end

  defp bundle_or_manifest_from_version(%{"manifest" => manifest}) when is_map(manifest),
    do: {:ok, manifest}

  defp bundle_or_manifest_from_version(_version),
    do: {:error, "version does not include a manifest"}

  defp next_version(deployment_key) do
    case RedisStore.list_job_versions(deployment_key) do
      {:ok, []} ->
        "1"

      {:ok, versions} ->
        versions
        |> Enum.map(&version_integer(&1["version"]))
        |> Enum.max()
        |> Kernel.+(1)
        |> to_string()

      _ ->
        "1"
    end
  end

  defp deployment_id(deployment_key) do
    safe_key =
      deployment_key
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
      |> String.trim("-")

    "dep_#{safe_key}_#{System.unique_integer([:positive])}"
  end

  defp version_integer(version) do
    case Integer.parse(to_string(version)) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp same_topology?(%Manifest{} = left, %Manifest{} = right) do
    topology_signature(left) == topology_signature(right)
  end

  defp topology_signature(manifest) do
    %{
      nodes: Enum.map(manifest.nodes, & &1.node_id) |> Enum.sort(),
      edges:
        manifest.edges
        |> Enum.map(&{&1.from_node, &1.to_node, &1.message_type, &1.routing_mode})
        |> Enum.sort(),
      entrypoints: Enum.sort(manifest.entrypoints || [])
    }
  end

  defp changed_source_agent_ids(old_manifest, new_manifest) do
    old_nodes = Map.new(old_manifest.nodes, &{&1.node_id, node_compare_map(&1)})

    new_manifest.nodes
    |> Enum.filter(fn node -> Map.get(old_nodes, node.node_id) != node_compare_map(node) end)
    |> Enum.map(& &1.node_id)
  end

  defp node_compare_map(node) do
    node
    |> Map.take([:agent_type, :type, :role, :config, :resources, :constraints, :services])
    |> json_safe()
  end

  defp runtime_agent_ids(scheduler_plan, source_agent_ids) do
    source_set = MapSet.new(source_agent_ids)
    placements = Map.get(scheduler_plan, "placements", [])

    case placements do
      [] ->
        source_agent_ids

      placements ->
        placements
        |> Enum.filter(fn placement ->
          MapSet.member?(source_set, placement["source_agent_id"] || placement["agent_id"])
        end)
        |> Enum.map(& &1["agent_id"])
        |> Enum.reject(&is_nil/1)
    end
  end

  defp canary_count(policy, agent_ids) do
    count = length(agent_ids)
    canary = policy["canary"] || 0

    cond do
      count == 0 -> 0
      canary > 0 -> min(canary, count)
      policy["strategy"] == "canary" -> 1
      true -> 0
    end
  end

  defp ensure_status(%{"status" => status}, expected) when status == expected, do: :ok

  defp ensure_status(%{"status" => status}, expected),
    do: {:error, "deployment is #{status}, expected #{expected}"}

  defp maybe_cancel_source_job(nil, _target_job_id), do: :ok
  defp maybe_cancel_source_job(source_job_id, source_job_id), do: :ok

  defp maybe_cancel_source_job(source_job_id, _target_job_id) do
    case MirrorNeuron.cancel(source_job_id) do
      {:ok, _status} -> :ok
      _other -> :ok
    end
  end

  defp health_summary(job) do
    %{
      "job_status" => job["status"],
      "updated_at" => job["updated_at"] || Runtime.timestamp()
    }
  end

  defp deployment_event(type, fields) do
    fields
    |> Map.put("type", type)
    |> Map.put("timestamp", Runtime.timestamp())
  end

  defp append_deployment_event(deployment, type, fields) do
    deployment
    |> Map.get("events", [])
    |> List.wrap()
    |> Kernel.++([deployment_event(type, fields)])
    |> Enum.take(-100)
  end

  defp filter_deployments(deployments, opts) do
    key = Keyword.get(opts, :deployment_key)
    status = Keyword.get(opts, :status)

    Enum.filter(deployments, fn deployment ->
      (is_nil(key) or deployment["deployment_key"] == key) and
        (is_nil(status) or deployment["status"] == status)
    end)
  end

  defp json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, json_safe(value)}
    end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value
end
