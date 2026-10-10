defmodule MirrorNeuron.Runtime.RunRetry do
  @moduledoc "Operator-authorized retries from verified logical checkpoints."
  alias MirrorNeuron.{JobBundle, Manifest}
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Bundle.{Archive, Fingerprint}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  alias MirrorNeuron.Runtime.{
    EventBus,
    JobRunner,
    RecoverySafety,
    RetryArtifacts,
    StableJob,
    WorkflowRetry
  }

  @version "mn.run_checkpoint/v1"

  def invocation_config(config, context) do
    environment = config["environment"] || %{}

    if environment["MN_RUN_RETRY_JSON"] do
      with true <- is_integer(context.lease_epoch) and context.lease_epoch > 0,
           {:ok, job} <- RedisStore.fetch_job(context.job_id),
           :ok <- RedisStore.validate_job_attempt_epoch(context.job_id, context.lease_epoch),
           true <- job["status"] == "running" and is_map(job["retry_request"]) do
        clock = job["running_time"] || %{}

        retry = %{
          "configuration_overrides" => effective_overrides(job),
          "consumed_seconds" => (clock["accumulated_ms"] || 0) / 1000,
          "active_since" => clock["active_since"],
          "attempt" => job["attempt"]
        }

        {:ok,
         Map.put(
           config,
           "environment",
           Map.put(environment, "MN_RUN_RETRY_JSON", Jason.encode!(retry))
         )}
      else
        _ ->
          {:error,
           %{
             "error" => "Retry execution no longer has a verified running lease.",
             "retryable" => false
           }}
      end
    else
      {:ok, config}
    end
  end

  def checkpoint(job, ledger, artifacts \\ %{}) do
    %{
      "version" => @version,
      "run_id" => job["run_id"] || job["job_id"],
      "job_id" => job["stable_job_id"],
      "attempt" => job["attempt"],
      "data_generation" => job["data_generation"],
      "manifest_digest" => digest(job["manifest"]),
      "inputs_digest" => digest(job["inputs"]),
      "running_time" => job["running_time"],
      "configuration_overrides" => effective_overrides(job),
      "workflow" => ledger,
      "artifacts" => artifacts,
      "created_at" => Runtime.timestamp()
    }
    |> then(&Map.put(&1, "revision", digest(&1)))
  end

  def plan(run_id, overrides \\ %{}) do
    with {:ok, job} <- RedisStore.fetch_job(run_id) do
      case prepare(job, overrides) do
        {:ok, prepared} ->
          {:ok, public_plan(job, prepared)}

        {:error, reason} ->
          {:ok,
           %{
             "run_id" => run_id,
             "job_id" => job["stable_job_id"],
             "eligible" => false,
             "reason" => if(is_binary(reason), do: reason, else: Runtime.error_message(reason)),
             "preserved_steps" => [],
             "retry_steps" => []
           }}
      end
    end
  end

  def submit(run_id, attrs) do
    with {:ok, job} <- RedisStore.fetch_job(run_id) do
      StableJob.with_start_gate(job["stable_job_id"] || run_id, fn ->
        with {:ok, current} <- RedisStore.fetch_job(run_id) do
          key = attrs["idempotency_key"]

          cond do
            not is_binary(key) or byte_size(key) not in 1..255 ->
              {:error, {:invalid_run_retry, "An idempotency key is required."}}

            is_map(get_in(current, ["retry_receipts", key])) ->
              saved = current["retry_receipts"][key]

              if saved["request_digest"] == digest(attrs),
                do: {:ok, saved["receipt"]},
                else:
                  {:error,
                   {:run_retry_blocked, "Idempotency key was used for different retry settings."}}

            true ->
              do_submit(current, attrs)
          end
        end
      end)
    end
  end

  defp do_submit(job, attrs) do
    with {:ok, prepared} <- prepare(job, attrs["configuration_overrides"] || %{}),
         true <-
           attrs["expected_attempt"] == job["attempt"] and
             attrs["checkpoint_revision"] == prepared.checkpoint["revision"],
         :ok <- inactive(job),
         {:ok, workflow} <- WorkflowRetry.restore(prepared.ledger, Runtime.timestamp()) do
      request =
        attrs
        |> Map.put("request_digest", digest(attrs))
        |> Map.put(
          "effective_configuration_overrides",
          Map.merge(effective_overrides(job), attrs["configuration_overrides"] || %{})
        )

      opts = [
        job_bundle: prepared.bundle,
        bundle_ref: job["manifest_ref"],
        checkpoint_retry: %{job: job, workflow: workflow, request: request},
        run_id: job["run_id"] || job["job_id"],
        stable_job_id: job["stable_job_id"],
        data_generation: job["data_generation"],
        job_data_dir: job["job_data_dir"],
        job_data_access: job["job_data_access"],
        scheduler_plan: job["scheduler"],
        requested_recovery_policy: job["requested_recovery_policy"],
        recovery_policy: job["recovery_policy"],
        reliability: job["reliability"]
      ]

      case Horde.DynamicSupervisor.start_child(
             MirrorNeuron.Runtime.JobSupervisor,
             {JobRunner, {job["job_id"], prepared.bundle.manifest, opts}}
           ) do
        {:ok, _pid} ->
          {:ok, current} = RedisStore.fetch_job(job["job_id"])

          EventBus.publish(job["job_id"], %{
            type: :run_retry_accepted,
            attempt: current["attempt"],
            checkpoint_revision: prepared.checkpoint["revision"],
            timestamp: Runtime.timestamp()
          })

          {:ok, current["retry_receipts"][attrs["idempotency_key"]]["receipt"]}

        {:error, reason} ->
          {:error,
           {:run_retry_blocked, "Retry could not start: #{Runtime.error_message(reason)}"}}
      end
    else
      false -> {:error, {:run_retry_blocked, "The run changed. Review the retry plan again."}}
      {:error, {_kind, _reason}} = error -> error
      {:error, reason} -> {:error, {:run_retry_blocked, reason}}
    end
  end

  # Called only after JobRunner has acquired a new fenced lease.
  def begin_attempt(job_id, manifest, %{job: prior, workflow: workflow, request: request}, lease) do
    with {:ok, current} <- RedisStore.fetch_job(job_id),
         true <- current["status"] == "failed" and current["attempt"] == prior["attempt"] do
      attempt = prior["attempt"] + 1

      history =
        List.wrap(prior["attempt_history"]) ++
          [
            %{
              "attempt" => prior["attempt"],
              "action" => "failed",
              "result_ref" => prior["result_ref"],
              "at" => prior["updated_at"]
            },
            %{
              "attempt" => attempt,
              "action" => "checkpoint_retry",
              "at" => Runtime.timestamp(),
              "checkpoint_revision" => request["checkpoint_revision"],
              "configuration_overrides" => request["configuration_overrides"] || %{}
            }
          ]

      accepted = %{
        "run_id" => prior["run_id"] || job_id,
        "job_id" => prior["stable_job_id"],
        "attempt" => attempt,
        "attempt_id" => "#{prior["run_id"] || job_id}:#{attempt}",
        "status" => "accepted"
      }

      receipts =
        Map.put(prior["retry_receipts"] || %{}, request["idempotency_key"], %{
          "request_digest" => request["request_digest"],
          "receipt" => accepted
        })

      RedisStore.persist_terminal_job(job_id, %{
        "status" => "pending",
        "attempt" => attempt,
        "attempt_id" => "#{prior["run_id"] || job_id}:#{attempt}",
        "workflow_state" => workflow,
        "manifest" => Manifest.to_map(manifest),
        "restart_reason" => "checkpoint_retry",
        "recovery_mode" => "checkpoint_retry",
        "retry_request" => request,
        "attempt_history" => history,
        "retry_receipts" => receipts,
        "pending_workflow_completion" => nil,
        "recovery_requires_review" => false,
        "recovery" => nil,
        "attempt_started_at" => nil,
        "attempt_not_before" => nil,
        "restart_budget" => nil,
        "result" => nil,
        "result_ref" => nil,
        "workflow_state_ref" => nil,
        "lease" => lease,
        "lease_epoch" => lease["epoch"],
        "lease_owner" => lease["owner_id"]
      })
    else
      _ -> {:error, {:run_retry_blocked, "The failed run changed before retry."}}
    end
  end

  defp prepare(job, overrides) do
    with :ok <- failed(job),
         {:ok, checkpoint} <- load_checkpoint(job),
         :ok <- checkpoint_identity(job, checkpoint),
         {:ok, manifest} <- Manifest.load(job["manifest"]),
         {:ok, bundle} <- verified_bundle(job, manifest),
         :ok <- generation(job),
         :ok <- verified_inputs(manifest),
         :ok <- inactive(job),
         :ok <- validate_overrides(manifest, overrides),
         {:ok, _restored} <- WorkflowRetry.restore(checkpoint["workflow"], Runtime.timestamp()),
         :ok <- completed_work_matches(job, checkpoint["workflow"]),
         :ok <- verify_references(checkpoint["workflow"]),
         :ok <- verify_boundaries(checkpoint["workflow"]),
         :ok <- safe_work(job, checkpoint["workflow"], manifest, checkpoint["artifacts"] || %{}) do
      {:ok,
       %{
         checkpoint: checkpoint,
         ledger: checkpoint["workflow"],
         bundle: bundle,
         fields: effective_fields(job, manifest)
       }}
    end
  rescue
    _ -> {:error, "Checkpoint data is invalid or incomplete. Start a new run."}
  end

  defp failed(%{"status" => "failed"}), do: :ok
  defp failed(_), do: {:error, "Only failed runs can be retried. Resume a paused run instead."}

  defp completed_work_matches(job, ledger) do
    current = job["workflow_state"] || %{}
    current_steps = current["steps"] || %{}

    if Enum.all?(current_steps, fn {id, step} ->
         step["status"] not in ~w(completed partial) or
           get_in(ledger, ["steps", id, "status"]) == step["status"]
       end),
       do: :ok,
       else: {:error, "The checkpoint is missing completed work. Start a new run."}
  end

  defp load_checkpoint(job) do
    case RedisStore.fetch_run_checkpoint(job["job_id"]) do
      {:ok, checkpoint} ->
        {:ok, checkpoint}

      {:error, :checkpoint_not_found} ->
        if StagedArtifact.ref?(job["workflow_state_ref"]) do
          ledger = StagedArtifact.resolve!(job["workflow_state_ref"], timeout_ms: 0)
          {:ok, checkpoint(job, ledger)}
        else
          {:error, "History is available, but no durable checkpoint remains. Start a new run."}
        end

      error ->
        error
    end
  rescue
    _ -> {:error, "Checkpoint artifacts are missing or could not be verified."}
  end

  defp checkpoint_identity(job, checkpoint) do
    if checkpoint["version"] == @version and
         checkpoint["run_id"] == (job["run_id"] || job["job_id"]) and
         checkpoint["job_id"] == job["stable_job_id"] and checkpoint["attempt"] == job["attempt"] and
         checkpoint["data_generation"] == job["data_generation"] and
         checkpoint["manifest_digest"] == digest(job["manifest"]) and
         checkpoint["inputs_digest"] == digest(job["inputs"]) and
         checkpoint["revision"] == digest(Map.delete(checkpoint, "revision")),
       do: :ok,
       else: {:error, "Checkpoint identity or integrity does not match this run."}
  end

  defp verified_bundle(job, manifest) do
    fingerprint = get_in(job, ["manifest_ref", "bundle_fingerprint"])

    if is_binary(fingerprint) and fingerprint != "" do
      with {:ok, bundle} <- Archive.load(fingerprint),
           {:ok, ^fingerprint} <- Fingerprint.compute(bundle.root_path) do
        {:ok, %{bundle | manifest: manifest}}
      else
        _ -> {:error, "The original executable bundle is missing or changed."}
      end
    else
      JobBundle.load(Manifest.to_map(manifest))
    end
  end

  defp generation(%{"stable_job_id" => id} = job) when is_binary(id) do
    with {:ok, definition} <- StableJob.get(id),
         true <-
           definition["status"] == "active" and
             List.wrap(definition["resource_cleanup_errors"]) == [] and
             definition["data_generation"] == job["data_generation"] do
      :ok
    else
      _ -> {:error, "Job data was reset or the co-worker is no longer active."}
    end
  end

  defp generation(_), do: :ok

  defp verified_inputs(manifest) do
    case MirrorNeuron.Artifacts.SubmissionReadiness.verify(Manifest.to_map(manifest)) do
      {:ready, _} ->
        :ok

      _ ->
        {:error,
         "Original staged inputs are missing or changed. Restore them or start a new run."}
    end
  end

  defp inactive(job) do
    runner = Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job["job_id"]})
    coordinator = Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job["job_id"]})

    with [] <- runner,
         [] <- coordinator,
         {:ok, nil} <- RedisStore.get_lease("job:#{job["job_id"]}") do
      if is_binary(job["stable_job_id"]) do
        with {:ok, runs} <- StableJob.list_runs(job["stable_job_id"]) do
          if Enum.any?(runs, &(&1["status"] in ~w(pending running paused cancelling))),
            do: {:error, {:run_retry_blocked, "Another run is active. Stop it before retrying."}},
            else: :ok
        end
      else
        :ok
      end
    else
      _ ->
        {:error,
         {:run_retry_blocked, "Previous attempt cleanup or another execution is still active."}}
    end
  end

  defp validate_overrides(manifest, overrides)
       when is_map(overrides) and map_size(overrides) <= 32 do
    fields = get_in(manifest.metadata, ["run_retry", "configuration_fields"]) || %{}

    if Enum.all?(overrides, fn {path, value} ->
         case fields[path] do
           %{"type" => "integer", "minimum" => low, "maximum" => high} ->
             is_integer(value) and value >= low and value <= high

           %{"type" => "string", "allowed_values" => values} ->
             is_binary(value) and value in values

           _ ->
             false
         end
       end),
       do: :ok,
       else:
         {:error,
          "Retry settings are not declared adjustable or are outside their allowed range."}
  end

  defp validate_overrides(_, _), do: {:error, "Retry settings must be a bounded object."}

  defp safe_work(job, ledger, manifest, artifacts) do
    steps = Enum.map(WorkflowRetry.unfinished(ledger), &ledger["steps"][&1])

    missing_nodes =
      Enum.filter(steps, fn step ->
        (step["attempt_count"] || 0) > 0 and
          not Map.has_key?(ledger["child_workflows"] || %{}, step["id"]) and
          not Enum.any?(manifest.nodes, &(&1.node_id in (step["agent_ids"] || [step["run"]])))
      end)

    if missing_nodes != [], do: raise(ArgumentError, "Checkpoint execution identity is missing")

    unsafe =
      Enum.flat_map(steps, fn step ->
        if Map.get(step, "attempt_count", 0) > 0 and
             not Map.has_key?(ledger["child_workflows"] || %{}, step["id"]) do
          manifest.nodes
          |> Enum.filter(&(&1.node_id in (step["agent_ids"] || [step["run"]])))
          |> Enum.filter(&(&1.agent_type in ["module", "executor"]))
          |> Enum.reject(&RecoverySafety.config_retry_safe?(&1.config))
          |> Enum.map(&{step["id"] <> ":" <> &1.node_id, &1})
        else
          []
        end
      end)

    handoff_steps =
      for {id, node} <- unsafe,
          get_in(node.config, ["artifact_handoff", "version"]) == "mn.artifact_handoff/v1",
          do: id

    with {:ok, safe} <- RetryArtifacts.verify(job, ledger, manifest, handoff_steps, artifacts) do
      blocked = for {id, _node} <- unsafe, id not in safe, do: id

      if blocked == [],
        do: :ok,
        else: {:error, "Uncertain external effects block replay: #{Enum.join(blocked, ", ")}."}
    end
  end

  defp verify_boundaries(ledger) do
    preserved = WorkflowRetry.preserved(ledger)

    missing =
      Enum.filter(WorkflowRetry.unfinished(ledger), fn id ->
        step = ledger["steps"][id]

        parents =
          for edge <- ledger["edges"] || [], edge["to"] == id, do: edge["from"]

        (Map.get(step, "attempt_count", 0) > 0 or Enum.all?(parents, &(&1 in preserved))) and
          is_nil(step["last_message"]) and is_nil(step["instance_input"]) and
          not StagedArtifact.ref?(step["last_message_ref"]) and
          not Map.has_key?(ledger["child_workflows"] || %{}, id)
      end)

    if missing == [],
      do: :ok,
      else:
        {:error,
         "Unfinished step inputs are missing: #{Enum.join(missing, ", ")}. Start a new run."}
  end

  defp verify_references(value) when is_map(value) do
    if Enum.any?(Map.keys(value), &String.ends_with?(to_string(&1), "_ref_error")) do
      {:error, "A checkpoint output could not be retained. Start a new run."}
    else
      if StagedArtifact.ref?(value) do
        value |> StagedArtifact.resolve!(timeout_ms: 0) |> verify_references()
      else
        Enum.reduce_while(Map.values(value), :ok, fn item, :ok ->
          case verify_references(item) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    end
  rescue
    _ -> {:error, "A checkpoint artifact is missing or has changed."}
  end

  defp verify_references(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case verify_references(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_references(_), do: :ok

  defp public_plan(job, prepared) do
    %{
      "run_id" => job["run_id"] || job["job_id"],
      "job_id" => job["stable_job_id"],
      "eligible" => true,
      "reason" => nil,
      "expected_attempt" => job["attempt"],
      "checkpoint_revision" => prepared.checkpoint["revision"],
      "preserved_steps" => WorkflowRetry.preserved(prepared.ledger),
      "retry_steps" => WorkflowRetry.unfinished(prepared.ledger),
      "configuration_fields" => prepared.fields,
      "running_time" => job["running_time"],
      "retained_bytes" => byte_size(Jason.encode!(prepared.checkpoint))
    }
  end

  defp effective_overrides(job),
    do: get_in(job, ["retry_request", "effective_configuration_overrides"]) || %{}

  defp effective_fields(job, manifest) do
    original =
      Enum.find_value(manifest.nodes, %{}, fn node ->
        case get_in(node.config, ["environment", "MN_BLUEPRINT_CONFIG_JSON"]) do
          value when is_binary(value) ->
            case Jason.decode(value) do
              {:ok, config} when is_map(config) -> config
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    Map.new(get_in(manifest.metadata, ["run_retry", "configuration_fields"]) || %{}, fn {path,
                                                                                         field} ->
      value = Map.get(effective_overrides(job), path) || get_in(original, String.split(path, "."))
      {path, Map.put(field, "current_value", value)}
    end)
  end

  def digest(value),
    do:
      value
      |> canonical()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp canonical(value) when is_map(value),
    do:
      value
      |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [k, v] end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
