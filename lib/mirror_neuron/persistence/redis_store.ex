defmodule MirrorNeuron.Persistence.RedisStore do
  @moduledoc "Persistence API delegating to domain stores with shared Redis transport and fencing."

  alias MirrorNeuron.Persistence.RedisStore.Admission
  alias MirrorNeuron.Persistence.RedisStore.Agents
  alias MirrorNeuron.Persistence.RedisStore.Blobs
  alias MirrorNeuron.Persistence.RedisStore.Bundles
  alias MirrorNeuron.Persistence.RedisStore.Checkpoints
  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Deployments
  alias MirrorNeuron.Persistence.RedisStore.Events
  alias MirrorNeuron.Persistence.RedisStore.FederationProjections
  alias MirrorNeuron.Persistence.RedisStore.Guards
  alias MirrorNeuron.Persistence.RedisStore.JobCleanup
  alias MirrorNeuron.Persistence.RedisStore.JobDefinitions
  alias MirrorNeuron.Persistence.RedisStore.JobIndex
  alias MirrorNeuron.Persistence.RedisStore.Jobs
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Leases
  alias MirrorNeuron.Persistence.RedisStore.Nodes
  alias MirrorNeuron.Persistence.RedisStore.Recovery
  alias MirrorNeuron.Persistence.RedisStore.Retention
  alias MirrorNeuron.Persistence.RedisStore.RuntimeStatus
  alias MirrorNeuron.Persistence.RedisStore.Schedules
  alias MirrorNeuron.Persistence.RedisStore.Services

  defdelegate fetch_run_start_request(identity), to: Checkpoints
  defdelegate persist_run_start_request(identity, request), to: Checkpoints
  defdelegate fetch_node_admission(node_name), to: Admission
  defdelegate fetch_admission_job(id), to: Admission
  defdelegate compare_node_admission(node, version, next), to: Admission
  defdelegate compare_node_admission(node, version, next, witness), to: Admission
  defdelegate write_queue_schedule(node, version, witness, existing, attrs), to: Admission

  @doc """
  Return the opaque identity and writable-primary state of the Redis plane.

  The identity is created once in the configured namespace and replicated by
  Redis. A process connected directly to a replica can read the identity, but
  is never reported as a writable runtime endpoint.
  """
  defdelegate coordination_store_status(), to: Connection
  @doc false
  defdelegate persist_run_checkpoint(job_id, checkpoint, epoch), to: Checkpoints
  defdelegate fetch_run_checkpoint(job_id), to: Checkpoints
  defdelegate discard_run_checkpoint(job_id), to: Checkpoints
  defdelegate retained_checkpoint_storage(), to: Checkpoints
  @doc false
  defdelegate clear_job_attempt_state(job_id), to: Checkpoints
  @doc false
  defdelegate validate_job_attempt_epoch(job_id, epoch), to: Guards
  defdelegate persist_job(job_id, job_map), to: Jobs
  @doc false
  defdelegate persist_terminal_transition(job_id, job_map, event), to: Jobs
  @doc false
  defdelegate persist_job_projection(job_id, job_map), to: Jobs
  @doc false
  defdelegate put_federation_projections(owner_node, kind, summaries), to: FederationProjections

  @doc false
  defdelegate replace_federation_projections(owner_node, kind, summaries),
    to: FederationProjections

  @doc false
  defdelegate list_federation_projections(owner_node, kind), to: FederationProjections

  @doc false
  defdelegate fetch_federation_projection(owner_node, kind, resource_id),
    to: FederationProjections

  @doc false
  defdelegate delete_federation_projection(owner_node, kind, resource_id),
    to: FederationProjections

  @doc false
  defdelegate delete_federation_projections(owner_node), to: FederationProjections
  defdelegate persist_terminal_job(job_id, updates), to: Jobs
  defdelegate persist_terminal_job(job_id, updates, defaults), to: Jobs
  defdelegate fetch_job(job_id), to: Jobs
  defdelegate fetch_delivery_settings(job_id), to: Jobs
  defdelegate fetch_job_summary(job_id), to: Jobs
  defdelegate list_job_ids(), to: Jobs
  defdelegate list_jobs(), to: Jobs
  defdelegate list_job_summaries(), to: Jobs

  @doc """
  Persists a stable job definition independently from execution records.

  Execution records use `job:<run_id>`. Stable definitions use
  `job-definition:<job_id>` so the two identities cannot overwrite one another.
  """
  defdelegate persist_job_definition(job_id, definition), to: JobDefinitions
  @doc false
  defdelegate create_job_definition(job_id, definition), to: JobDefinitions
  @doc false
  defdelegate compare_job_definition(job_id, revision, definition), to: JobDefinitions
  defdelegate fetch_job_definition(job_id), to: JobDefinitions
  defdelegate job_definition_exists?(job_id), to: JobDefinitions
  defdelegate execution_exists?(run_id), to: Jobs
  defdelegate list_job_definitions(), to: JobDefinitions
  defdelegate delete_job_definition(job_id), to: JobDefinitions
  defdelegate reserve_schedule_occurrence(schedule_id, token, record, lock), to: Schedules
  defdelegate complete_schedule_occurrence(schedule_id, token, record, lock), to: Schedules
  defdelegate persist_schedule(schedule_id, schedule_map), to: Schedules

  defdelegate persist_schedule_fenced(schedule_id, schedule_map, lease_name, owner_id, epoch),
    to: Schedules

  defdelegate fetch_schedule(schedule_id), to: Schedules
  defdelegate list_schedules(), to: Schedules
  defdelegate list_due_schedules(now_iso), to: Schedules
  defdelegate delete_schedule(schedule_id), to: Schedules
  defdelegate delete_schedule_fenced(schedule_id, lease_name, owner_id, epoch), to: Schedules
  defdelegate append_trigger_event(event_id, event_map), to: Schedules
  defdelegate list_trigger_events(), to: Schedules
  defdelegate list_trigger_events(limit), to: Schedules
  defdelegate persist_deployment(deployment_id, deployment_map), to: Deployments
  defdelegate fetch_deployment(deployment_id), to: Deployments
  defdelegate fetch_deployment_by_key(deployment_key), to: Deployments
  defdelegate fetch_deployment_ref(id_or_key), to: Deployments
  defdelegate list_deployments(), to: Deployments
  defdelegate persist_job_version(deployment_key, version, version_map), to: Deployments
  defdelegate fetch_job_version(deployment_key, version), to: Deployments
  defdelegate list_job_versions(deployment_key), to: Deployments
  defdelegate append_event(job_id, event), to: Events
  @doc false
  defdelegate append_event_if_job_exists(job_id, event), to: Events
  defdelegate read_events(job_id), to: Events
  defdelegate read_events(job_id, start), to: Events
  defdelegate read_events(job_id, start, stop), to: Events
  defdelegate replace_job_events(job_id, events), to: Events
  @doc false
  defdelegate persist_agent(job_id, agent_id, snapshot), to: Agents
  defdelegate persist_agent(job_id, agent_id, snapshot, opts), to: Agents
  defdelegate list_agents(job_id), to: Agents
  defdelegate list_agent_summaries(job_id), to: Agents
  defdelegate fetch_agent(job_id, agent_id), to: Agents
  defdelegate repair_recovery_indexes(), to: JobIndex
  defdelegate delete_job(job_id), to: JobCleanup
  defdelegate delete_job(job_id, opts), to: JobCleanup
  defdelegate sweep_retention(), to: Retention
  defdelegate sweep_retention(opts), to: Retention
  defdelegate acquire_lease(lease_name, owner_id, ttl_ms), to: Leases
  defdelegate renew_lease(lease_name, owner_id, ttl_ms), to: Leases
  defdelegate release_lease(lease_name, owner_id), to: Leases
  defdelegate get_lease(lease_name), to: Leases
  defdelegate acquire_fenced_lease(lease_name, owner_id, ttl_ms), to: Leases
  defdelegate persist_service_instance(instance_id, service_map), to: Services
  defdelegate update_service_instance_if_exists(instance_id, service_map), to: Services
  defdelegate fetch_service_instance(instance_id), to: Services
  defdelegate list_service_instances(), to: Services
  defdelegate list_service_instances(opts), to: Services
  defdelegate delete_service_instance(instance_id), to: Services
  defdelegate delete_service_instances(opts), to: Services
  defdelegate renew_fenced_lease(lease_name, owner_id, epoch, ttl_ms), to: Leases
  defdelegate release_fenced_lease(lease_name, owner_id, epoch), to: Leases
  defdelegate release_ephemeral_fenced_lease(lease_name, owner_id, epoch), to: Leases
  defdelegate persist_bundle_archive(fingerprint, archive), to: Bundles
  defdelegate fetch_bundle_archive(fingerprint), to: Bundles
  defdelegate refresh_bundle_archive(fingerprint), to: Bundles
  defdelegate expire_unreferenced_bundle_archives(referenced_fingerprints), to: Bundles
  defdelegate referenced_bundle_fingerprints(), to: Bundles
  defdelegate register_blob_ref(ref), to: Blobs
  defdelegate fetch_blob_ref(sha256), to: Blobs
  defdelegate list_blob_refs(), to: Blobs
  defdelegate persist_node_state(node_name, attrs), to: Nodes
  defdelegate persist_node_runtime_status(node_name, domain, snapshot), to: RuntimeStatus
  defdelegate read_node_runtime_status_events(node_name), to: RuntimeStatus
  defdelegate read_node_runtime_status_events(node_name, count), to: RuntimeStatus
  defdelegate ack_node_runtime_status_events(node_name, event_ids), to: RuntimeStatus
  defdelegate runtime_status_snapshots(domains), to: RuntimeStatus
  defdelegate read_node_cluster_runtime_status_events(node_name), to: RuntimeStatus
  defdelegate read_node_cluster_runtime_status_events(node_name, count), to: RuntimeStatus
  defdelegate ack_node_cluster_runtime_status_events(node_name, event_ids), to: RuntimeStatus
  defdelegate fetch_node_state(node_name), to: Nodes
  defdelegate list_node_states(), to: Nodes
  defdelegate persist_recovery_eval(eval_id, eval_map), to: Recovery
  defdelegate fetch_recovery_eval(eval_id), to: Recovery
  defdelegate list_recovery_evals(), to: Recovery
  defdelegate list_recovery_evals(statuses), to: Recovery
  defdelegate update_recovery_eval(eval_id, updates), to: Recovery
  defdelegate fetch_resource_limits(), to: Admission
  defdelegate persist_resource_limits(limits), to: Admission

  defdelegate fetch_cancellation(run_id),
    to: MirrorNeuron.Persistence.CancellationStore,
    as: :fetch

  defdelegate enqueue_delivery(job_id, agent_id, message, opts),
    to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate read_deliveries(job_id, agent_id, consumer, opts),
    to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate ack_delivery(job_id, agent_id, consumer, stream_id, message_id, ack_ttl_seconds),
    to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate dead_letter_delivery(job_id, agent_id, stream_id, message_id, reason, ttl_seconds),
    to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate renew_delivery(job_id, agent_id, consumer, stream_id),
    to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate retry_delivery(job_id, agent_id, consumer, stream_id, delay_ms, lease_ms),
    to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate fetch_delivery_receipt(job_id, agent_id, message_id),
    to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate delivery_pending_count(job_id, agent_id), to: MirrorNeuron.Persistence.DeliveryStore

  defdelegate expire_job_deliveries(job_id, ttl_seconds),
    to: MirrorNeuron.Persistence.DeliveryStore

  @doc false
  def storage_command(args), do: Connection.command(args)

  @doc false
  def storage_pipeline(commands), do: Connection.pipeline(commands)

  @doc false
  def storage_barrier, do: Connection.wait_for_replicas()

  @doc false
  def storage_key(parts), do: Enum.join([Keys.namespace() | parts], ":")
end
