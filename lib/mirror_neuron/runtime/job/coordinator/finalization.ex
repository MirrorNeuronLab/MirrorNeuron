defmodule MirrorNeuron.Runtime.JobCoordinator.Finalization do
  @moduledoc "Fenced terminal commits, staged results and completion publication."

  require Logger

  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Processes
  alias MirrorNeuron.Runtime.JobCoordinator.RecoveryTasks
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots
  alias MirrorNeuron.Runtime.JobCoordinator.Values
  alias MirrorNeuron.Runtime.WorkflowLedger
  alias MirrorNeuron.ServiceRegistry

  def finalize_job(state, status, result, event_type, event_fields) do
    epoch = get_in(Keyword.get(state.opts, :job_lease, %{}), ["epoch"])

    case RedisStore.validate_job_attempt_epoch(state.job_id, epoch) do
      :ok -> finalize_current_job(state, status, result, event_type, event_fields)
      _ -> %{state | status: status}
    end
  end

  defp finalize_current_job(state, status, result, event_type, event_fields) do
    if status == "failed",
      do:
        MirrorNeuron.Runtime.Signals.error(
          state.job_id,
          "workflow",
          "run",
          failure_error(state, result, event_fields),
          :terminal
        )

    state = state |> Policy.cancel_policy_timers() |> RecoveryTasks.cancel_recovery_tasks()
    Processes.terminate_agent_workers(state)
    ServiceRegistry.deregister_job(state.job_id)
    {result, event_fields} = attach_failure_error(state, status, result, event_type, event_fields)
    {result, event_fields} = finalize_shared_storage(state, status, result, event_fields)

    Snapshots.persist_retry_checkpoint(state)
    finished_workflow = WorkflowLedger.finish(state.workflow_state, status)
    result = strip_result_workflow_state(result)

    {result_ref, workflow_state_ref} =
      stage_terminal_snapshots(state, result, finished_workflow)

    compact_result = compact_terminal_result(status, result, result_ref, workflow_state_ref)
    compact_workflow = WorkflowLedger.compact_snapshot(finished_workflow)

    next_state = %{
      state
      | status: status,
        result: compact_result,
        result_ref: result_ref,
        workflow_state_ref: workflow_state_ref,
        workflow_state: compact_workflow,
        pending_workflow_completion: nil
    }

    history =
      List.wrap(state.attempt_history) ++
        [
          %{
            "attempt" => state.attempt,
            "action" => status,
            "at" => Runtime.timestamp(),
            "result_ref" => result_ref,
            "workflow_state_ref" => workflow_state_ref
          }
        ]

    next_state = %{next_state | attempt_history: history}

    event =
      event_fields
      |> Map.drop([:output, :result, :workflow_state, "output", "result", "workflow_state"])
      |> maybe_put_event_ref(:payload_ref, result_ref)
      |> maybe_put_event_ref(:result_ref, result_ref)
      |> maybe_put_event_ref(:workflow_state_ref, workflow_state_ref)
      |> Map.put(:type, event_type)
      |> Map.put(:timestamp, Runtime.timestamp())

    event =
      case MirrorNeuron.Runtime.Finalization.commit(
             state.job_id,
             Snapshots.job_snapshot(state),
             Snapshots.job_snapshot(next_state),
             event,
             notify: fn _, _ -> :ok end
           ) do
        {:ok, committed} -> committed[:terminal_event]
        {:error, reason} -> exit({:shutdown, {:finalization_persistence_failed, reason}})
      end

    run_id = WorkflowLedger.run_id(finished_workflow) || state.job_id

    case SharedStorage.publish_run_completion(
           state.definition.manifest,
           run_id,
           status,
           get_in(Keyword.get(state.opts, :job_lease, %{}), ["epoch"]) || 0
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to publish shared run completion: #{inspect(reason)}")
    end

    _ = Runtime.cleanup_job_sandboxes(next_state.job_id)
    EventBus.dispatch_persisted(state.job_id, event)
    MirrorNeuron.Runtime.CommandReceipts.settle_run_async(state.job_id)
    MirrorNeuron.Runtime.Signals.finish_run_async(state.job_id, status)

    next_state
  end

  defp strip_result_workflow_state(result) when is_map(result) do
    result
    |> Map.delete(:workflow_state)
    |> Map.delete("workflow_state")
  end

  defp strip_result_workflow_state(result), do: result

  defp stage_terminal_snapshots(state, result, workflow_state) do
    manifest = MirrorNeuron.Manifest.to_map(state.manifest)
    run_id = WorkflowLedger.run_id(workflow_state) || state.job_id

    result_ref =
      stage_terminal_snapshot(result, manifest,
        kind: "job_result",
        run_id: run_id
      )

    workflow_state_ref =
      stage_terminal_snapshot(workflow_state, manifest,
        kind: "workflow_state",
        run_id: run_id
      )

    {result_ref, workflow_state_ref}
  end

  defp stage_terminal_snapshot(value, manifest, opts) do
    case StagedArtifact.stage_from_manifest(value, manifest, opts) do
      {:ok, reference} ->
        reference

      {:error, reason} ->
        Logger.warning("failed to stage terminal artifact: #{inspect(reason)}")
        nil
    end
  end

  defp compact_terminal_result(status, result, result_ref, workflow_state_ref) do
    summary =
      inline_terminal_result(result)
      |> Map.put("status", status)

    summary
    |> maybe_put_event_ref("result_ref", result_ref)
    |> maybe_put_event_ref("workflow_state_ref", workflow_state_ref)
  end

  defp inline_terminal_result(result) when is_map(result) do
    if StagedArtifact.inline_value?(result) do
      Values.stringify_map(result)
    else
      result
      |> Map.take([
        :agent_id,
        "agent_id",
        :error,
        "error",
        :failure,
        "failure",
        :finalization_warnings,
        "finalization_warnings"
      ])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
    end
  end

  defp inline_terminal_result(result) do
    if StagedArtifact.inline_value?(result), do: %{"output" => result}, else: %{}
  end

  defp maybe_put_event_ref(map, _key, nil), do: map

  defp maybe_put_event_ref(map, key, reference), do: Map.put(map, key, reference)

  defp finalize_shared_storage(state, status, result, event_fields) do
    manifest = MirrorNeuron.Manifest.to_map(state.manifest)

    case SharedStorage.finalize_terminal_job(state.job_id, manifest, status) do
      {:ok, []} ->
        {result, event_fields}

      {:ok, warnings} ->
        {put_finalization_warnings(result, warnings),
         Map.put(event_fields, :finalization_warnings, warnings)}

      {:error, warnings} ->
        {put_finalization_warnings(result, warnings),
         Map.put(event_fields, :finalization_warnings, warnings)}
    end
  end

  defp put_finalization_warnings(nil, warnings), do: %{"finalization_warnings" => warnings}

  defp put_finalization_warnings(result, warnings) when is_map(result) do
    Map.put(result, "finalization_warnings", warnings)
  end

  defp put_finalization_warnings(result, warnings) do
    %{"result" => result, "finalization_warnings" => warnings}
  end

  defp attach_failure_error(state, "failed", result, _event_type, event_fields) do
    error = failure_error(state, result, event_fields)
    desc = ErrorEnvelope.desc(error)

    event_fields =
      event_fields
      |> Map.put(:error, error)
      |> Map.put(:reason, desc)
      |> Map.put(:status_reason, desc)

    {failure_result(result, error, desc, event_fields), event_fields}
  end

  defp attach_failure_error(state, _status, result, :job_failed, event_fields) do
    attach_failure_error(state, "failed", result, :job_failed, event_fields)
  end

  defp attach_failure_error(_state, _status, result, _event_type, event_fields),
    do: {result, event_fields}

  defp failure_error(_state, result, event_fields) do
    reason =
      Values.get_any(event_fields, [
        :error,
        "error",
        :reason,
        "reason",
        :status_reason,
        "status_reason"
      ]) ||
        Values.get_any(result, [
          :error,
          "error",
          :reason,
          "reason",
          :status_reason,
          "status_reason"
        ]) ||
        "job failed"

    ErrorEnvelope.normalize(reason,
      component: "job_coordinator",
      step_id:
        Values.get_any(event_fields, [:step_id, "step_id", :step, "step"]) ||
          Values.get_any(result, [:step_id, "step_id", :step, "step"]),
      agent_id:
        Values.get_any(event_fields, [:agent_id, "agent_id"]) ||
          Values.get_any(result, [:agent_id, "agent_id"]),
      node: to_string(Node.self())
    )
  end

  defp failure_result(result, error, desc, event_fields) when is_map(result) do
    result
    |> Values.stringify_map()
    |> Map.put("error", error)
    |> Map.put("reason", desc)
    |> Map.put("status_reason", desc)
    |> Map.put_new("step_id", Values.get_any(event_fields, [:step_id, "step_id", :step, "step"]))
    |> Map.put_new("agent_id", Values.get_any(event_fields, [:agent_id, "agent_id"]))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp failure_result(result, error, desc, _event_fields) do
    %{
      "error" => error,
      "reason" => desc,
      "status_reason" => desc,
      "value" => Values.stringify(result)
    }
  end
end
