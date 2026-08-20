# MirrorNeuron Core Specification

## Purpose

MirrorNeuron Core is the Elixir/OTP execution runtime for durable,
message-driven workflows. It loads executable manifests and job bundles,
supervises long-lived runtime nodes, schedules work across local or clustered
resources, persists lifecycle state, and exposes control and observability over
gRPC.

This specification covers only Core. Source-manifest compilation, terminal and
HTTP adapters, domain blueprints, reusable Python agents/skills, context memory,
and desktop presentation are separate contracts consumed by Core.

## Public Surfaces

- `MirrorNeuron`: in-process job, deployment, schedule, cluster, inspection,
  backup, and control facade.
- `lib/mirror_neuron_grpc/` with `proto/*.proto`: remote control,
  observability, job, cluster, and durable operation services.
- executable job manifests and bundles accepted by `JobBundle`/`Manifest`.
- Redis-backed job, cancellation, operation/event, delivery, schedule,
  deployment, and snapshot records.
- structured runtime events, error envelopes, artifacts, and runner results.

Exact function and RPC definitions are authoritative. Changes to these surfaces
are compatibility-sensitive.

## Runtime Model

A stable job definition owns a validated bundle, resolved configuration,
schedules, storage declarations, owner node, lifecycle state, data generation,
and persistent `job_id`. Each intentional execution creates a distinct
`run_id`; retry and recovery attempts retain that run and use an independent
attempt identity. Public stable-job responses are bounded projections: they
carry a durable bundle reference and lifecycle/configuration metadata, never
the embedded expanded manifest, private runtime paths, or the full run-ID
history. A submitted bundle is loaded, normalized, validated, checked
for services and requirements, admitted to resources, and started under
per-run supervision.
An inactive stable job may atomically replace its executable bundle only when
the graph and blueprint identities are unchanged. Replacement preserves job
data, schedules, and run history. Run preparation rewrites only run/attempt
identity and run-output locations; submission IDs, containers, input roots,
and definition-owned resources remain immutable until a later bundle
replacement retires them.
Runtime nodes are long-lived OTP processes. Generic built-ins and templates
route messages and invoke configured runner behavior.

Logical workflow steps are bounded by generated step-source/join/sink controls.
Internal worker communication does not independently complete a logical step.
The workflow ledger and persisted job status are the durable account of
progress; events are the observable account of transitions.

## Delivery Contract

Messages have explicit identity, sender/recipient information, payload,
attempt/lease state, and bounded lifetime. Delivery enforces configured queue
limits, backpressure, claim/lease, ACK, retry, deduplication, and dead-letter
behavior. A message is not considered successfully handled until the owning
delivery/lifecycle boundary records that outcome.

Retries preserve identity and must not cause duplicate logical completion or
unbounded side effects. Expired, exhausted, invalid, or permanently failed
messages follow the declared failure/dead-letter path.

## Lifecycle and Persistence

Stable-job, run, and agent lifecycle transitions are validated and persisted.
Persistent shared data is derived as `$MN_HOME/job-data/<job-id>` and is never
owned by run retention or cleanup. Run state, submissions, sandboxes, logs, and
artifacts are run-scoped. Archive retains job data; reset advances the data
generation; confirmed job deletion waits for or rejects active runs before
removing the definition and data. Terminal run
states are completed, failed, or cancelled. `cancelling` is a fenced,
non-recoverable transition: durable cancellation intent revokes the old lease,
rejects stale coordinator/agent writes, and prevents recovery, resume,
scheduling, and drain migration until locally owned cleanup is acknowledged.
Terminal-run clearing removes job-owned HostLocal processes, DockerWorker and
OpenShell sandboxes, checkpoints, services, staged storage, artifacts, leases,
delivery state, and Redis records on every recorded runtime node before the run
is reported as cleared. The legacy local-node identity `nonode@nohost` is
normalized to the current local runtime during cleanup rather than treated as a
remote cluster node. A durably fenced `cancelling` run is the exception:
public state and global artifacts may be cleared while an internal cancellation
tombstone retains pending runtime nodes and the write fence. Rejoining nodes
finish local cleanup by run ID, and the final acknowledgement releases the
fence without recreating public job or event records. Confirmed stable-job
deletion removes schedules and applies that cleanup to every historical run before removing
definition-owned resources,
job data, and the definition.
Cancellation reconciliation scans a pending-only Redis index in one server-side
operation. Acknowledgement removes the index entry but retains the durable
cancellation record for audit.
Pause, resume, cancel, backup, restore, deployment, and schedule operations
preserve event/status coherence.
Pausing a service terminates its owned HostLocal commands and sandboxes while
retaining resumable workflow state. A retry-safe auxiliary service-agent
failure reuses durable command redelivery while its healthy supervising agent
stays alive, so unrelated effectful workflow steps are not replayed and the
live job does not enter operator review solely because an auxiliary endpoint
restarted.
Job backup and restore use the breaking `mn.backup.v2` contract. Core owns the
durable runtime snapshot and bundle map; adapters may add verified
content-addressed payload blobs, wheels, images, and compatibility metadata for
air-gapped transport. Core does not implement or accept `mn.backup.v1`.

Fixed server-defined group-operation kinds persist their immutable target
snapshot, item states, counters, errors, timestamps, and replayable progress
events in Redis. OTP-supervised runners apply bounded unordered concurrency;
unfinished work is resumed after a Core restart. A request is successful when
durable cancellation intent has been committed even when remote cleanup remains
pending.

Redis is the sole durable coordination store. Shared artifact storage retains
declared artifacts, but local disk checkpoints are not a recovery source.
Recovery verifies runtime identity, bundle compatibility, ownership, and
manifest-declared retry safety before starting a clean job attempt.
Automatic node reconciliation and orphan sweeps treat `paused_for_review` as a
stable operator-owned state: they do not create a new recovery evaluation or
republish the same pause event on each scan.
Periodic local recovery makes the same decision from compact job summaries and
also skips jobs whose runner is live before loading their full state.
Compact monitoring reads separately persisted agent projections containing only
liveness, queue pressure, error, lease, and sandbox fields; local agent state,
inflight payloads, pending payload copies, and recovery encodings are never
persisted. Active lease, cancellation, and retention decisions use a compact
per-job guard. A job control record retains its manifest, status, bundle
reference, attempt, retry budget, lease epoch, and terminal result. Agent,
coordinator, node, or host loss advances the fenced lease epoch, clears
attempt-owned observations and deliveries, resets the workflow ledger, and
seeds manifest inputs into a new attempt. Effectful executor and module nodes
must declare retry safety or an idempotency key before automatic redo; otherwise
the job pauses for operator approval. Terminal recovery evaluations receive
their TTL once when they become terminal.
Retention removes only eligible terminal/history data according to configured
policy, prunes expired indexes server-side, and never renews terminal TTLs.
The node-local LiteLLM gateway admits inference through a bounded shared FIFO
queue so parallel worker containers cannot start enough simultaneous local
model decoders to starve Core lease and coordination work. Queue admission,
wait, release, timeout, and saturation are emitted as structured events.

## Cluster and Resources

Core uses OTP distribution, `libcluster`, and Horde-based runtime coordination
for clustered operation. Membership, leader/control forwarding, node state,
draining, reconciliation, and network-only nodes are explicit. A control-node
call must preserve the public result of the same local operation.

Scheduling and admission consider declared CPU, memory, GPU, services, models,
node state, and execution profiles. Lack of an admissible placement returns an
actionable failure; it does not bypass requirements.
Declared inbound ports may be fixed integers or request runtime allocation with
`"auto"`. The scheduler makes automatic ports exclusive per active placement
on a target node, persists the resolved integer in the scheduler plan, exports
it through `MN_PORT_<LABEL>`, and resolves agent service templates from that
same allocation. Runtime nodes may constrain the allocatable range with
`MN_AUTO_PORT_START` and `MN_AUTO_PORT_END` when their container or firewall
publishes only a bounded port range.
The public job-collaboration service contract is `mn-job-collaboration` with
tags `mcp` and `job-collaboration`, loopback Streamable HTTP at `/mcp`, and
blueprint/job/run/goal identity metadata. It is run-scoped and read-only;
distributed authenticated discovery and job mutation are outside this
contract. The persistent supervisory MCP at
`/api/v1/jobs/{job_id}/mcp` is owned by `mn-api`: it projects stable Core state
without an active Run and does not extend the lifetime or mutation authority of
this Core-owned peer-collaboration service.
Every Redis namespace carries an opaque coordination-store identity. Runtime
nodes advertise that identity, Redis role, and writable-primary status.
If Redis is still loading or its status cannot be read, self-advertisement
fails without persisting a cordoned node so the supervised monitor retries.
Scheduling excludes nodes that do not match the submitting Core's writable
primary and reports `coordination_store_mismatch` before a run enters
`running`. A manifest declaring `runtime.placement.mode=single_node` is rejected
if its final lowered plan spans more than one node.

## Execution and Isolation

Runner policy selects host-local, Docker, or OpenShell execution according to
the executable manifest/profile. Core stages bounded inputs, passes explicit
environment/config, captures a structured result, registers durable artifacts,
and cleans up only owned resources. HostLocal commands run in an owned process
group when the host supports it; cancellation, owner termination, timeout, and
missed-beacon failure terminate that command before releasing the runner.
The published Core image provides Python 3.11 for HostLocal blueprint commands.
When a prepared `python_environment` is attached, HostLocal resolves console
script entrypoints from that environment's `bin` directory before the Core
process path.
Its build fails if `python3` does not resolve to Python 3.11; the base image is
pinned by Debian release and multi-architecture digest so immutable Core
release behavior cannot drift with an upstream rolling tag.
HostLocal commands receive a loopback `MN_GRPC_TARGET` derived from Core's
internal gRPC listen port so bind and externally advertised addresses are never
mistaken for client destinations; an explicit manifest environment override
remains authoritative.
DockerWorker command environments include
the runtime-owned `MN_EXECUTION_NODE` value for the Core node actually invoking
the command; manifest environment cannot override that placement identity.
OpenShell CLI subprocesses give `OPENSHELL_GATEWAY_ENDPOINT` precedence over an
inherited `OPENSHELL_GATEWAY` selector for every sandbox lifecycle operation;
direct-endpoint command execution uses the gRPC exec transport with closed stdin.
An OpenShell worker may explicitly set `sync_shared_storage=true`. Core then
mirrors only the job-scoped `inputs` and `outputs` directories into an
invocation-owned sandbox path, rewrites references rooted at
`MN_JOB_SHARED_STORAGE_ROOT`, and synchronizes `outputs` back before accepting
the worker result.

Isolation and network policies are least privilege. Blueprint-specific binaries,
packages, domains, ports, and private IP allowances remain in blueprint/runtime
policy rather than global Core defaults.

## Configuration and Security

Runtime configuration is defined by `config/` and `MirrorNeuron.Config`. Real
environment values take precedence over environment-file defaults. Production
rejects known insecure defaults and requires configured authentication where
the schema says so.

Manifests, gRPC calls, remote-node data, Redis records, file paths, environment
values, uploads, and runner output are untrusted. Size, path, fan-out, TTL,
queue, resource, and command limits are enforced before expensive or dangerous
work. Secrets never appear in events or ordinary logs.

## Job and run API

`mirrorneuron.job.v1.JobService` is the sole authoritative protobuf contract.
It exposes durable definition and explicit run operations only; no legacy
submission, deployment, general-schedule, backup/restore, bulk-cancel, clear,
alias, or dual-registration surface is provided. Runtime environment code must
not interpret `MN_JOB_ID` as a run identity; it uses `MN_RUN_ID` and
`MN_ATTEMPT_ID` explicitly. See `JOBS_AND_RUNS.md` for the complete contract.

## Acceptance

```bash
mix format --check-formatted
mix test
mix compile --warnings-as-errors
```

Shell scripts also pass `bash -n`. Unit tests cover deterministic behavior;
Redis, OpenShell, Docker, and multi-node paths receive focused integration/E2E
coverage when those contracts change.
