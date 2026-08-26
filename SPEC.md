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
and persistent `job_id`. Batch jobs retain one-to-many execution history and
each intentional execution creates a distinct `run_id`. An executable manifest
whose authoritative `type` is `service` instead retains at most one attached
run; pause and resume preserve that run identity. Retry and recovery attempts
retain their run and use an independent attempt identity. Public stable-job responses are bounded projections: they
carry a durable bundle reference and lifecycle/configuration metadata, never
the embedded expanded manifest, private runtime paths, or the full run-ID
history. A submitted bundle is loaded, normalized, validated, checked
for services and requirements, admitted to resources, and started under
per-run supervision.
The service workflow entrypoint has no implicit batch deadline or beacon
deadline. An explicit entrypoint `timeout_seconds` and optional
`beacon_timeout_ms` remain authoritative; downstream and batch steps retain
their bounded defaults.
An inactive stable job may atomically replace its executable bundle only when
the graph and blueprint identities are unchanged. Replacement preserves job
data, schedules, and run history. Run preparation rewrites only run/attempt
identity and run-output locations; submission IDs, containers, input roots,
and definition-owned resources remain immutable until a later bundle
replacement retires them.
Ordinary service starts fail with the stable `service_run_exists` conflict when
any run is attached. Explicit replacement requires a fresh run ID, validates
before cleanup, durably cancels active work, permanently clears every old
run-scoped record and artifact, and then attaches one fresh run. Job data,
configuration, schedules, and definition identity remain intact. Retried
replacement with the already-attached fresh ID returns that run.
An executable manifest may opt into one definition-scoped response service with
the singular top-level `response_service` declaration. A declaration may be the
literal `{"enabled": true}` or include one validated bounded MCP agent. That
agent may declare an optional live read preflight for selected effects; the
preflight must name a declared read tool, match its arguments exactly, and
require only scalar result fields.
Core starts it asynchronously on the owner node, routes bounded unary queries
to that owner, retries failed or degraded warm-ups with bounded backoff, and
stops it for archive, reset, deletion, and definition replacement. Response
queries never create Runs.
Federated job and run controls resolve an owner on demand when a projection has
not yet synchronized, so any connected Core can operate a remote durable
definition or run. If a known remote owner is unavailable during archive, the
submitting Core durably records an archive tombstone, projects the stale remote
definition with status `archive_pending`, and replays the archive when that peer
reconnects. The tombstone is
cleared after any reachable owner response, preventing later implicit retries
of a rejected archive. A confirmed archive immediately updates the submitting
Core's projection instead of waiting for the next federation sync.
Owner-forwarded job and run deletion use a bounded five-minute request deadline
instead of the ordinary 15-second federation request deadline. Connection
establishment remains bounded by the ordinary deadline, while confirmed cleanup
has time to cancel runs and retire each owned runtime resource.
Stable-job lookup and lifecycle atoms map to semantic gRPC statuses (`NOT_FOUND`,
`ALREADY_EXISTS`, `FAILED_PRECONDITION`, or `INVALID_ARGUMENT`); a missing
resource on one peer must not surface as `INTERNAL` or abort owner discovery.
Federated runtime-model and LiteLLM route controls honor their requested
`node` owner through the same scoped Core-to-Core forwarding path, so SDK and
CLI callers use any joined Core as a secure ingress rather than peer tokens.
Runtime nodes are long-lived OTP processes. Generic built-ins and templates
route messages and invoke configured runner behavior.

Logical workflow steps are bounded by generated step-source/join/sink controls.
Internal worker communication does not independently complete a logical step.
The workflow ledger and persisted job status are the durable account of
progress; events are the observable account of transitions.

`MirrorNeuron.Runner.DockerCompose` is a native-host runner for a declared,
payload-relative Compose source tree. Core communicates with the selected
node's SDK through prepare, status, and cleanup gRPC calls; the native service
runs Docker only with the returned project record. It must never reuse the
MirrorNeuron runtime Compose file or DockerWorker's generated worker project.

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
generation; confirmed job deletion durably cancels and clears all active runs
before removing the definition and data. Confirmed run deletion likewise
durably cancels and clears an active run before detaching it from its definition.
Terminal run
states are completed, failed, or cancelled. `cancelling` is a fenced,
non-recoverable transition: durable cancellation intent revokes the old lease,
rejects stale coordinator/agent writes, and prevents recovery, resume,
scheduling, and drain migration until locally owned cleanup is acknowledged.
Terminal-run clearing removes job-owned HostLocal processes, DockerWorker and
DockerCompose projects, OpenShell sandboxes, services, staged storage, artifacts, leases,
delivery state, and Redis records on every recorded runtime node before the run
is reported as cleared. A durably fenced `cancelling` run is the exception:
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
Service schedules are lifecycle schedules: an occurrence starts when no run is
attached, resumes a paused run, no-ops when it is already pending/running,
replaces terminal history, and blocks while cancellation or ambiguous
active history remains. A window end pauses rather than cancels; overlapping
windows pause only when the last window for that job/run closes. Dispatch audit
records retain the action, old/new run IDs, and deferred cleanup state.
Pausing a service terminates its owned HostLocal commands and sandboxes while
retaining resumable workflow state. A retry-safe auxiliary service-agent
failure reuses durable command redelivery while its healthy supervising agent
stays alive, so unrelated effectful workflow steps are not replayed and the
live job does not enter operator review solely because an auxiliary endpoint
restarted.
Job backup and restore use the breaking `mn.backup.v2` contract. Core owns the
durable runtime snapshot and bundle map; adapters may add verified
content-addressed payload blobs, wheels, images, and verified transport metadata for
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
Federation handshakes advertise the owner's complete hardware profile. Resource
reports preserve both direct scheduler eligibility and the separate federated
owner eligibility facts, so submitters can validate a remote owner without
making that owner a member of their local scheduler.
Service discovery aggregates each authenticated federated owner's local
registry in one hop, preserving the normal service filters without recursively
forwarding a peer request.
Declared inbound ports may be fixed integers or request runtime allocation with
`"auto"`. The scheduler makes automatic ports exclusive per active placement
on a target node, persists the resolved integer in the scheduler plan, exports
it through `MN_PORT_<LABEL>`, and resolves agent service templates from that
same allocation. Runtime nodes may constrain the allocatable range with
`MN_AUTO_PORT_START` and `MN_AUTO_PORT_END` when their container or firewall
publishes only a bounded port range.
Response-enabled Jobs use the owner-node, definition-scoped response
supervisor. The MCP transport at `/api/v1/jobs/{job_id}/mcp` is owned by
`mn-api`; it projects stable Core state and dispatches response questions
through the bounded Core RPC without extending a Run.
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
It exposes durable definition, optional definition-response queries, and
explicit run operations only. Submission, deployment, general-schedule,
backup/restore, bulk-cancel, clear, alias, and dual-registration operations are
not part of this service. Runtime environment code must
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
