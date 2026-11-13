defmodule MirrorNeuron.Runtime.JobCoordinator.Snapshots do
  @moduledoc "Bounded run projections, durable snapshots and retry checkpoints."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobCoordinator.Context
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.WorkflowLedger

  def persist_job(state) do
    job_map = job_snapshot(state)

    if state.status == "running" do
      persist_job_projection(state, job_map)
    else
      persist_durable_job_snapshot(state, job_map)
    end
  end

  def job_snapshot(state) do
    lease = Keyword.get(state.opts, :job_lease)

    %{
      job_id: state.job_id,
      delivery_version: Map.get(state, :delivery_version, 2),
      run_id: Keyword.get(state.opts, :run_id, state.job_id),
      workflow_run_id: WorkflowLedger.run_id(state.workflow_state),
      stable_job_id: Keyword.get(state.opts, :stable_job_id),
      attempt_id: "#{Keyword.get(state.opts, :run_id, state.job_id)}:#{state.attempt}",
      data_generation: Keyword.get(state.opts, :data_generation),
      job_data_dir: Keyword.get(state.opts, :job_data_dir),
      job_data_access: Keyword.get(state.opts, :job_data_access),
      graph_id: state.manifest.graph_id,
      job_name: state.manifest.job_name,
      required_context_engine: Map.get(state.manifest, :required_context_engine, false),
      status: state.status,
      pause_cleanup_status: if(state.status == "paused", do: state.pause_cleanup_status),
      admission: Keyword.get(state.opts, :admission),
      clock_session: state.clock_session,
      attempt: state.attempt,
      attempt_started_at: state.attempt_started_at,
      attempt_not_before: state.attempt_not_before,
      attempt_history: state.attempt_history,
      retry_receipts: state.retry_receipts,
      workflow_budgets: Map.get(state, :workflow_budgets, %{}),
      restart_budget: state.restart_budget,
      restart_reason: state.restart_reason,
      recovery_mode:
        if(Keyword.has_key?(state.opts, :checkpoint_retry),
          do: "checkpoint_retry",
          else: "clean_restart"
        ),
      retry_request: Keyword.get(state.opts, :checkpoint_retry, %{})[:request],
      submitted_at: Map.get(state, :submitted_at, Runtime.timestamp()),
      updated_at: Runtime.timestamp(),
      root_agent_ids: state.manifest.entrypoints,
      placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
      job_type: Topology.scheduler_plan(state)["job_type"],
      scheduler: Topology.scheduler_plan(state),
      requested_recovery_policy: Policy.requested_recovery_policy(state),
      recovery_policy: Policy.effective_recovery_policy(state),
      reliability_degraded: Policy.reliability_degraded?(state),
      reliability: Policy.reliability_map(state),
      restart_policy: Policy.job_restart_policy(state),
      reschedule_policy: Policy.job_reschedule_policy(state),
      policy_state: %{"agents" => %{}},
      workflow_state: persistable_terminal_workflow(state),
      pending_workflow_completion: nil,
      deployment: Topology.deployment_job_fields(state),
      result: state.result,
      inputs: state.manifest.initial_inputs || %{},
      outputs: state.result,
      artifact_references:
        [state.result_ref, state.workflow_state_ref]
        |> Enum.reject(&is_nil/1),
      result_ref: state.result_ref,
      workflow_state_ref: state.workflow_state_ref,
      topology: MirrorNeuron.Manifest.topology(state.manifest),
      runtime_topology: Topology.runtime_topology(state),
      manifest: state.definition.manifest,
      manifest_ref: Context.manifest_ref(state)
    }
    |> maybe_put_lease(lease)
    |> Map.merge(Map.get(state, :recovery_fields, %{}))
  end

  def persist_durable_job_snapshot(state, job_map) do
    case RedisStore.persist_job(state.job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to persist job #{state.job_id}: #{inspect(reason)}")
    end
  end

  defp persistable_terminal_workflow(%{status: status, workflow_state: workflow_state})
       when status in ["completed", "failed", "cancelled"] do
    WorkflowLedger.persistable_snapshot(workflow_state, nil)
  end

  defp persistable_terminal_workflow(_state), do: nil

  defp persist_job_projection(state, job_map) do
    case RedisStore.persist_job_projection(state.job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to persist job projection #{state.job_id}: #{inspect(reason)}")
    end
  end

  def persist_job_with_recovery(state, reason) do
    recovery = %{
      "status" => "paused_for_review",
      "mode" => "clean_restart",
      "reason" => reason,
      "requires_review" => true,
      "can_resume" => true,
      "updated_at" => Runtime.timestamp()
    }

    job_map =
      %{
        job_id: state.job_id,
        run_id: Keyword.get(state.opts, :run_id, state.job_id),
        workflow_run_id: WorkflowLedger.run_id(state.workflow_state),
        stable_job_id: Keyword.get(state.opts, :stable_job_id),
        attempt_id: "#{Keyword.get(state.opts, :run_id, state.job_id)}:#{state.attempt}",
        data_generation: Keyword.get(state.opts, :data_generation),
        job_data_dir: Keyword.get(state.opts, :job_data_dir),
        job_data_access: Keyword.get(state.opts, :job_data_access),
        graph_id: state.manifest.graph_id,
        job_name: state.manifest.job_name,
        required_context_engine: Map.get(state.manifest, :required_context_engine, false),
        status: "paused",
        clock_session: state.clock_session,
        attempt: state.attempt,
        attempt_started_at: state.attempt_started_at,
        attempt_not_before: state.attempt_not_before,
        attempt_history: state.attempt_history,
        restart_budget: state.restart_budget,
        restart_reason: reason,
        recovery_mode: "clean_restart",
        submitted_at: Map.get(state, :submitted_at, Runtime.timestamp()),
        updated_at: Runtime.timestamp(),
        root_agent_ids: state.manifest.entrypoints,
        placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
        job_type: Topology.scheduler_plan(state)["job_type"],
        scheduler: Topology.scheduler_plan(state),
        requested_recovery_policy: Policy.requested_recovery_policy(state),
        recovery_policy: Policy.effective_recovery_policy(state),
        reliability_degraded: Policy.reliability_degraded?(state),
        result: state.result,
        inputs: state.manifest.initial_inputs || %{},
        outputs: state.result,
        artifact_references:
          [state.result_ref, state.workflow_state_ref]
          |> Enum.reject(&is_nil/1),
        result_ref: state.result_ref,
        workflow_state_ref: state.workflow_state_ref,
        topology: MirrorNeuron.Manifest.topology(state.manifest),
        runtime_topology: Topology.runtime_topology(state),
        manifest: state.definition.manifest,
        manifest_ref: Context.manifest_ref(state),
        recovery: recovery,
        recovery_status: "paused_for_review",
        recovery_reason: reason,
        recovery_requires_review: true,
        reliability: Policy.reliability_map(state),
        restart_policy: Policy.job_restart_policy(state),
        reschedule_policy: Policy.job_reschedule_policy(state),
        policy_state: %{"agents" => %{}},
        workflow_state: nil,
        pending_workflow_completion: nil,
        deployment: Topology.deployment_job_fields(state)
      }
      |> maybe_put_lease(Keyword.get(state.opts, :job_lease))

    case RedisStore.persist_job(state.job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist profile recovery state for #{state.job_id}: #{inspect(persist_reason)}"
        )
    end
  end

  def persist_retry_checkpoint(state) do
    if WorkflowLedger.enabled?(state.workflow_state) do
      job = %{
        "job_id" => state.job_id,
        "run_id" => Keyword.get(state.opts, :run_id, state.job_id),
        "stable_job_id" => Keyword.get(state.opts, :stable_job_id),
        "attempt" => state.attempt,
        "data_generation" => Keyword.get(state.opts, :data_generation),
        "retry_request" => Keyword.get(state.opts, :checkpoint_retry, %{})[:request],
        "clock_session" => state.clock_session,
        "status" => state.status,
        "updated_at" => Runtime.timestamp()
      }

      job =
        case RedisStore.fetch_job_summary(state.job_id) do
          {:ok, record} ->
            Map.put(job, "running_time", MirrorNeuron.Runtime.RunClock.advance(record, job))

          _ ->
            job
        end

      ledger = WorkflowLedger.persistable_snapshot(state.workflow_state, state.manifest)
      artifacts = MirrorNeuron.Runtime.RetryArtifacts.capture(job, ledger, state.manifest)

      checkpoint =
        MirrorNeuron.Runtime.RunRetry.checkpoint(
          job,
          ledger,
          artifacts,
          state.definition.checkpoint_identity
        )

      epoch = get_in(Keyword.get(state.opts, :job_lease, %{}), ["epoch"])

      case RedisStore.persist_run_checkpoint(state.job_id, checkpoint, epoch) do
        :ok ->
          :ok

        {:error, _} ->
          Logger.warning("could not persist run retry checkpoint", job_id: state.job_id)
      end
    end
  end

  def recovery_fields_from(job) when is_map(job) do
    job
    |> Map.take([
      "recovery",
      "recovery_status",
      "recovery_reason",
      "recovery_requires_review",
      "restore_provenance"
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def recovery_fields_from(_job), do: %{}

  # The immutable definition stays with its coordinator. A child spec is copied
  # into the distributed supervisor and agent heaps for every node in the DAG.

  defp maybe_put_lease(map, nil), do: map

  defp maybe_put_lease(map, lease) do
    map
    |> Map.put(:lease, lease)
    |> Map.put(:lease_epoch, lease["epoch"])
    |> Map.put(:lease_owner, lease["owner_id"])
  end
end
