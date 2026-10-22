# MirrorNeuron Core Specification

Resource node projections preserve the native hardware snapshot's optional
`cpu.load_average_1m` as `cpu_load_average_1m`. Missing samples remain null.
This is measured one-minute load, not a reservation or CPU utilization ratio;
clients must label it accordingly and avoid treating unknown nodes as idle.

Child-round plan nodes accept an optional non-empty `label` of at most 1,024 UTF-8 bytes. Core persists it on the child instance and includes it in public topology events; omitted labels retain the template label or instance ID. Labels do not alter task identity, dependencies or execution.

## Managed model residency

Managed DMR models are retained by physical run identity on the native owner node.
Completion, failure, cancellation and deletion release those references. The last
reference invokes `docker model unload <model>` after active requests drain;
downloaded weights, configuration and installed-model ownership remain intact.
Concurrent runs (including runs of the same definition) keep independent
references. Paused runs retain their models. SDK-managed gateway requests also
retain the actual serving owner, including fallback routes.

Terminal run markers reject late preparation or requests. Failed unloads retain
retryable ownership records; the native resource reconciler retries when Core
confirms a terminal run, and preserves ambiguous ownership. Existing untracked
or interactive models are not automatically swept. Workers, native SDK/gateway,
and Core must be upgraded together for automatic terminal cleanup; changing
source does not update an installed binary runtime.

## Purpose

OpenShell shared-output downloads precede invocation workspace cleanup. With
shared storage enabled, the command wrapper retains its directory until transfer
succeeds; a failed transfer retains the mirror for recovery. Persistent workspaces
retain their files while their synchronized temporary mirror is removed.

MirrorNeuron Core is the Elixir/OTP execution runtime for durable,
message-driven workflows. It loads executable manifests and job bundles,
supervises long-lived runtime nodes, schedules work across local or clustered
resources, persists lifecycle state, and exposes control and observability over
gRPC.
For SDK-staged shared submissions, terminal runs publish `outputs/runs/<run-id>/.mn_completion.json`
with the final status and an inventory of durable regular files. The submitting
host uses this receipt to wait for replication before copying declared outputs.
Core never writes to a submitter-only host path on a remote worker node.

This specification covers only Core. Source-manifest compilation, terminal and
HTTP adapters, domain blueprints, reusable Python agents/skills, context memory,
and desktop presentation are separate contracts consumed by Core.

## Public Surfaces

Scheduling admission reads durable execution records to account for active and
paused resource reservations. Compact monitoring summaries omit placements and
must not be used to decide which ports, devices, or capacity are available.

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
history. The detail projection includes only the sanitized native-resource
ownership identity needed to distinguish a durable prepared definition from an
abandoned node-local preparation; it never exposes cleanup commands or paths. A submitted bundle is loaded, normalized, validated, checked
for services and requirements, admitted to resources, and started under
per-run supervision.

Before a workflow handler executes, Core admits its source delivery through the
owning ledger and returns the authoritative attempt context. Deliveries waiting
for dependencies are retried without running the handler.
Generated step sources admit every upstream delivery into the same owning
attempt so they can collect all declared inputs. This permission belongs only
to the compiled source boundary; other handlers cannot borrow a different
delivery's attempt. Child instances are admitted by their instance step ID,
and routing within their compiled template retains that instance's context.
Targets following child work consume the final ledger-owned parent output;
the parent sink's preliminary notification cannot start those targets.

Routing within one logical step retains its attempt, deadlines, graph identity
and step idempotency key. Crossing a logical-step boundary clears that context
for the destination's ledger admission. Runner `MN_WORKFLOW_IDEMPOTENCY_KEY`
identifies the individual worker delivery, derived from the step key, target
agent and stable message ID. It survives delivery replay and differs between
parallel workers. `MN_WORKFLOW_STEP_IDEMPOTENCY_KEY` retains the ledger key;
completion and stale-attempt fencing continue using the original message headers.

HostLocal binds `MN_BUNDLE_ROOT` to its staged invocation copy and
`MN_BLUEPRINT_MANIFEST_PATH` to that copy's `runtime/manifest.json`, overriding
inherited or definition-time paths. Installed SDK handlers use this binding;
their package location is not the blueprint location.

Runner command failures retain a structured `mn.error.v1` receipt through the
workflow ledger and terminal run action. `runtime.command.failed` carries the
exit code, runner and attempt count, a concise final diagnostic line, and a
secret-redacted bounded output tail so Python's final exception survives long
tracebacks. Raw stdout/result payload copies are excluded from this receipt.
Retry events publish the same readable description and structured error.

HostLocal uses the same runtime workflow-environment projection as Docker and
OpenShell. Auxiliary messages without workflow headers receive the owning
physical workflow run ID from runner options. Runtime workflow values outrank
definition-time environment values; `MN_RUN_ID` retains the execution identity.

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
For SDK-staged local inputs, Core verifies the versioned
`mn_storage.inputs.readiness` inventory on the owner node before it seeds a
workflow entrypoint. The run remains `pending` while Syncthing catches up,
emitting rate-limited `submission_storage_waiting` events, then emits
`submission_storage_ready` and dispatches automatically. A non-ready tree
fails before any source message on the configured
`MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS` deadline (default 1800) with a
`submission_storage_timeout` event. Legacy submissions without an inventory
remain immediate.
Only maps explicitly tagged with `type: blob_ref` are content-addressed payload
references. Integrity descriptors such as input-readiness inventories may carry
a `sha256` field without being materialized from the blob store.
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
SDK-derived response declarations retain their bounded UTF-8 manual, standard
Job activity watch, scalar tool schemas, and fixed operation-poll arguments.
Fixed arguments must match the declared poll-tool schema and cannot replace its
correlation identity. Core validates these existing MCP projections before Job
creation; the native response engine remains their execution owner.
Operations may correlate any declared user tool, including asynchronous reads,
with a declared internal polling tool. Read operations retain their read effect;
polling arguments, intervals, and deadlines remain validated and bounded.
Core starts it asynchronously on the owner node, routes bounded unary queries
to that owner, retries failed or degraded warm-ups with bounded backoff, and
stops it for archive, reset, deletion, and definition replacement. Response
command failures also re-warm the same definition with one pending retry per
Job, recovering engines lost during native responder restarts. Failed queries
and their effects are not replayed; the caller may explicitly retry after
recovery. Successful degraded semantic answers do not trigger this recovery.
Response queries never create Runs. Archive and confirmed deletion force-detach a
responder when its native shutdown is stalled, allowing the lifecycle change to
complete while native cleanup continues in the background. Reset retains strict
shutdown behavior because it immediately reuses the same job data.
Federated job and run controls resolve an owner on demand when a projection has
not yet synchronized, so any connected Core can operate a remote durable
definition or run. If a known remote owner is unavailable during archive, the
submitting Core durably records an archive tombstone, projects the stale remote
definition with status `archive_pending`, and replays the archive when that peer
reconnects. An offline confirmed deletion similarly records a delete tombstone,
hides the stale definition and run projections from normal lists, returns
`delete_pending`, and replays owner cleanup when that peer reconnects. Until the
owner confirms it, deletion is accepted but its remote data and runtime
resources are not yet removed. The tombstone is cleared after any reachable
owner response, preventing later implicit retries of a rejected archive or
deletion. A confirmed archive immediately updates the submitting Core's
projection instead of waiting for the next federation sync.
Owner-forwarded Job creation and bundle replacement use a bounded two-minute
request deadline for payload persistence and Job data initialization. Ordinary
reads and metadata-only updates keep the 15-second deadline; connection setup
is also unchanged. This preserves the same durable definition contract on
local and remote owners without retrying submission after a timeout.
Owner-forwarded job and run deletion use a bounded five-minute request deadline
instead of the ordinary 15-second federation request deadline. Connection
establishment remains bounded by the ordinary deadline, while confirmed cleanup
has time to cancel runs and retire each owned runtime resource.
Federated unary calls share a supervised, bounded authenticated connection pool
on worker and control nodes. Connection identity includes the remote peer,
local peer identity, endpoint, and a digest of the current peer credential.
Concurrent setup is coalesced, with at most 64 retained connections and 1,024
active or pending leases; excess callers receive an availability error. Caller
exit or checkout timeout releases its lease. Idle connections expire after five
minutes; an idle connection may be evicted for a new peer. Credential or endpoint
changes and transport/authentication failures retire channels without closing
other active requests. The pool never replays a failed command, changes an
operation deadline, or omits a durable interaction/review check. Streaming
operations and independent reachability probes retain their existing lifecycle.
Connection credentials are omitted from pool process status and crash diagnostics.
The observability event stream resolves the same run owner. A non-owner Core
proxies the owner's replay and live server stream in one federation hop, so
clients see workflow transitions without sharing Redis identities or polling a
Syncthing replica. Event payloads are relayed unchanged; local and legacy
streams continue to read the node-local event store and EventBus.
Stable-job lookup and lifecycle atoms map to semantic gRPC statuses (`NOT_FOUND`,
`ALREADY_EXISTS`, `FAILED_PRECONDITION`, or `INVALID_ARGUMENT`); a missing
resource on one peer must not surface as `INTERNAL` or abort owner discovery.
Stable-job detail includes a source-facing workflow projection with
logical steps, edges, and declared agent identities. It omits the executable
manifest, worker environment, payloads, and host paths so API clients can read
the saved shape without starting a run.
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

Updating an archived stable job with `status: active` restores the same definition
under the existing revision and start gate. Its owner, data generation, bundle,
configuration and run history remain intact. Reactivation reconciles its response
service without starting a run or reenabling paused schedules. Archiving continues
to require the dedicated archive operation; generic updates cannot bypass it.

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
Paused workflows preserve remaining step, child-workflow, heartbeat, and retry
time budgets. Pause cancels pending recovery work; recovery and deployment
requests cannot start agents while paused. Pause and resume wait for interrupted
HostLocal and DockerWorker commands to relinquish their owned processes.
DockerWorker uses Python 3 in its prepared worker image to supervise a separate
process group per invocation. Owner loss, timeout and cancellation reap that
group and its invocation workspace; they never remove or restart the shared
prepared container. Failed command cleanup retains live ownership for retry.
Before dispatch, DockerWorker verifies the exact definition-owned prepared
container. A container stopped by runtime shutdown is started in place; a
running container is left untouched. Missing, paused, or otherwise unavailable
containers fail before command execution. Core never rebuilds or replaces a
prepared container during this check.
Idempotency records are owned by a supervised runtime process rather than an
individual gRPC request process. An identical keyed Job, Run, or schedule
request therefore replays the original result after its first request handler
has exited; reusing the key with a different payload is rejected.
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
Portable durable-job backup and restore use `mn.backup.v3`. Core owns streamed
job snapshots; SDK adapters capture verified payload models, wheels and Docker
images for air-gapped transport. Historical internal `mn.backup.v2` snapshots
are separate from these portable durable-job capsules.

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
Completion and embedding lanes each default to five concurrent calls per model
group. Private owner routes also admit at most five calls per lane; an explicitly
lower configured concurrency limit remains authoritative.

## Cluster and Resources

Core uses OTP distribution, `libcluster`, and Horde-based runtime coordination
for clustered operation. Membership, leader/control forwarding, node state,
draining, reconciliation, and network-only nodes are explicit. A control-node
call must preserve the public result of the same local operation.

Scheduling and admission consider declared CPU, memory, GPU, services, models,
node state, and execution profiles. Lack of an admissible placement returns an
actionable failure; it does not bypass requirements.
Placement rejection details append `\nmn_admission_v1:` followed by bounded JSON
with at most 100 measured blockers and a `truncated` boolean when capped. Each blocker contains a symbolic SDK code,
one-based snapshot node index, optional validated friendly `node_label`, and
when known `resource`, `available`, `required`, `unit`, and comparison `operator`.
Free GPU memory is measured on otherwise compatible, unreserved devices using
the same scheduler matching predicate. CPU/GPU reservations are capacity errors;
missing hardware retains its hardware error identity. Core supplies facts; the
SDK owns numeric problem codes, safe messages, and remediation hints. The
existing rejection prefix and protobuf shapes remain compatible, and admission
never lowers a requirement to produce better diagnostics.
Federation handshakes advertise the owner's complete hardware profile. Resource
reports preserve both direct scheduler eligibility and the separate federated
owner eligibility facts, so submitters can validate a remote owner without
making that owner a member of their local scheduler.
Authenticated federation advertisements and refreshes also preserve the owner's
current admission capability, holder, FIFO, generation and legacy reservations
through node inspection and resource reports. Private native request claims are
excluded. New definition placement can prefer an idle compatible PC over a busy
peer; only the owner-local atomic claim authorizes execution. Prepared definitions
retain their existing owner and are not migrated by an inventory refresh.
Federated peer availability is based on authenticated gRPC reachability probes
at five-second intervals. Three consecutive failures mark a peer unavailable;
the first successful probe restores healthy status. Job and run projection
refresh failures mark cached summaries stale without changing peer availability.
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
The published Core image provides Python 3.12 for HostLocal blueprint commands.
When a prepared `python_environment` is attached, HostLocal resolves console
script entrypoints from that environment's `bin` directory before the Core
process path.
Its build fails if `python3` does not resolve to Python 3.12. The Elixir and
Python stages are pinned by Debian release and multi-architecture digest;
the Python stage supplies CPython independently of Debian's system Python.
HostLocal selects Python 3.12 when preparing dependency environments, and
recognizes `python`, `python3`, and `python3.12` commands and console scripts.
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
explicit run operations and durable-job backup/restore. Submission, deployment,
general-schedule, bulk-cancel, clear, alias, and dual-registration operations are
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

Stable Job summary and detail projections retain the definition revision so
HTTP and SDK callers can perform optimistic concurrency checks on mutations.


The current Compose template starts authenticated Membrane v2 with persistent
Markdown memory and CPU DuckDB processing. Set `MN_CONTEXT_AUTH_TOKEN` before
direct Compose startup; installed runtimes generate/reuse a private token and
forward it to workers. Membrane does not depend on Redis or a GPU compressor.
Optional last-resort record selection uses the existing LiteLLM `default` route
after CPU compaction. Context-purpose requests resolve the normal default route.
Deploy a matching SDK/engine release before
running new Markdown profiles; historical support snapshots remain unchanged.


The Core image also runs the LiteLLM gateway. Its Python environment includes
`grpcio>=1.82.1` and `protobuf>=7.35.1` for automatic Membrane `CompilePrompt`
requests; image construction validates the protobuf runtime compatibility.
Rebuilding the Membrane image alone cannot repair missing gateway dependencies.
The SDK stages and validates the actual RPC bindings when LiteLLM loads its
callback. This adds no blueprint dependencies or runtime package installation.

The gateway image pins LiteLLM 1.100.1 and applies a hash-checked build-time
correction to its streaming usage normalization. OpenAI-compatible usage
objects are converted to LiteLLM's `Usage` before final aggregation, preserving
provider prompt, completion, reasoning and cache counts across gateway hops.
This introduces no counting requests or token estimates. Image construction
runs the installed library against loopback-only synthetic streams with both
empty and non-empty choices; an upstream source change fails the build and
requires review. Rebuild the Core/gateway image to deploy this correction.

OpenShell buffers command output until completion, including artifact-handoff
workers. Its inherited node beacon timeout does not shorten a workflow task
deadline. Explicit workflow heartbeat controls remain authoritative; otherwise
the declared step timeout governs both fixed and child tasks.

## Runtime-owned child workflow rounds

The `workflow.child_workflows` contract admits bounded child templates beneath
one fixed parent step. `Runtime.ChildWorkflow` validates the planner's finite
DAG, commits immutable revisions and graph hashes, and creates namespaced
instances in the existing workflow ledger. Redis persistence, worker delivery,
resource admission and attempt fencing remain owned by the existing runtime.

The generated parent sink hands off completion, leaving the parent running.
Only after a complete child round can a new planner instance run. A final stop
maps the child's bounded output into the deferred sink result and releases the
parent exit. Children cannot modify parent inputs, parent edges, running work,
or another region. Invalid plans fail the parent and run before task dispatch.

Child plans (execute and stop) are limited to 128 KiB of compact UTF-8 JSON,
including task metadata and immutable artifact references. This accommodates
the admitted 128-step ceiling; large inputs and results remain in shared files
replicated by Syncthing. Older Core builds enforce 32 KiB, so deploy the matching
Core before submitting larger plans. Task and round limits are unchanged.

Child fields are additive to ledger v3 and restored with the existing topology.
Public events contain parent, round, revision and phase; completed worker payloads
are not public event bodies because they can contain confidential plans.
Completed child instances remain bounded by round/node limits and retain their
outcomes for inspection. Static and existing dynamic-region workflows preserve
their current execution semantics. Deploy this runtime together with the SDK
child-workflow compiler; no compatibility execution fallback is provided.

Validation: `mix test tests/unit/child_workflow_test.exs
 tests/unit/dynamic_workflow_test.exs tests/unit/workflow_ledger_test.exs --no-start`.

## Retired working-index lifecycle

The older Core lifecycle below applies only to `required_context_engine: true`.
New catalog Markdown profiles do not set that retired Redis-index requirement;
SDK `ContextSession` owns their Markdown lifecycle receipts.

Jobs with `required_context_engine: true` check Membrane's context service
at `MN_CONTEXT_ADDR`, the same address used by SDK workers.
Startup checks that address on the job owner; the legacy `CONTEXT_ENGINE_ADDR`
is used only when `MN_CONTEXT_ADDR` is unset or blank. An explicitly configured
unreachable service fails startup rather than probing a different service.
Jobs with this requirement may use Membrane's additive
`mn.context.working.v1` RPC. `Runtime.ContextMemory` binds cleanup to the persisted
stable job ID and run ID, using `MN_CONTEXT_REDIS_URL` from the common runtime
Redis environment. Length-framed keys isolate runs; identifiers cannot inject
Redis scan patterns. Cancellation attempts the index fence before stopping
workers, and acknowledges only after both succeed. An unavailable index does
not prevent worker shutdown. Cancellation reconciliation retries failures.

Deleting a run fences new memory writes, paginates `SCAN`, and `UNLINK`s at most
128 keys per command. Keep the cancellation tombstone; run IDs must not be
reused. Existing artifact cleanup owns source blobs and SQLite invocation
receipts. A memory failure cannot complete a logical step or alter its topology;
`needs_partition` is handled by an explicitly admitted domain result/planning
boundary. Public events do not carry source text or memory packet content.

DockerWorker workflow attempts, including dynamic child tasks, use the declared
step timeout as their default liveness deadline. Node-level beacon settings are
not applied because this runner does not stream workflow beacons. An explicit
workflow `control.beacon_timeout_ms` remains authoritative for workloads that
provide a separate beacon producer. HostLocal node beacon settings are unchanged.

Generated step sources consume authoritative upstream outputs carried by Core
workflow triggers after child-workflow completion. They preserve run-input
references and artifacts and retain the same one-dispatch-per-attempt behavior
as ordinary generated sink deliveries.


Native SDK runtime services publish fresh host hardware snapshots through the
`hardware` runtime-status domain every 30 seconds. Core uses those snapshots for
local admission and federated advertisements instead of retaining startup memory
readings. After 90 seconds without a refresh, advertised available memory becomes
zero until telemetry recovers. GPU vendor and capacity requirements remain enforced.

## Response tool descriptions

Bounded response-agent tools accept an optional non-empty `description` of at
most 1,200 Unicode code points after trimming. Core preserves this planner
guidance without changing effects, argument validation, or execution authority.
Deploy this validator with the matching SDK common and job-response packages
before loading description-bearing blueprint declarations.
# Managed desktop identity

When MN_NODE_NAME is supplied, Core validates that it is a valid distributed
name equal to Node.self() before starting supervision or accepting job/operation
RPCs. Node inspection must never advertise nonode@nohost as healthy or eligible.
System summary includes identity expected/actual/valid diagnostics.

Desktop endpoint updates come from version-1 runtime-network.json under MN_HOME,
bound to the current node name. Federation retries use capped exponential
backoff. Existing peer registrations may change endpoints only with the same
node name, coordination-store identity, and peer credential. Job projections
and ownership survive these updates. Unreachable peers retain their identity;
operators may need to re-add their current endpoint if no known address works.


## Durable batch schedule occurrences

Batch schedules reserve an occurrence in Redis before starting work. A reservation
binds the schedule and occurrence to one execution ID and survives dispatcher
lease expiry, process restart, and run-record retention. Event occurrences use
the event ID independently of retry time. Only the reservation creator may
submit an execution; retries reconcile the exact recorded run and verify its
schedule/dispatch metadata, or return the durable submission receipt.

If interruption leaves a reservation without a verifiable run, dispatch reports
`schedule_occurrence_unconfirmed` for operator review; absence is not treated as
permission to execute again. A fresh intentional occurrence remains independent.
Receipts live until their owning schedule is deleted. Schedule deletion removes
them with the schedule under the same fenced mutation.

Dispatch bookkeeping failures are reported as failures. Receipt replay preserves
the original submission time and does not extend an already recorded execution
window or count the same retained dispatch twice. Service schedules retain their
existing single-run pause/resume/replacement behavior.

## Durable human interaction capability (cutover pending)

The interaction persistence adapter restores schema-declared list fields after
Redis Lua JSON decoding: options, fields, field options, presentation items and
sources remain arrays when empty. This applies to command receipts, reads,
snapshots and replay, including records already stored by Lua. Object fields and
answer values retain their original shape. HTTP/desktop consumers continue to
validate the canonical contract without storage-specific coercion.

`mn.interaction.v1` stores versioned requests and replay events atomically in Redis.
The `mirrorneuron.interactions.v1.InteractionService` Command and Watch RPCs use
the existing authenticated channel and JSON resource envelope. Explicit option
IDs and semantics, expected revisions and command IDs are required. Request
state is separate from effect state. Scope binds the original execution;
federated commands route to its owner. Snapshots include an opaque composite
cursor; expired cursors require resynchronization. Response receipts survive
transport loss and only one concurrent decision can commit.

The implementation retains at most 10,000 replay events and 5,000 records per
node; resolved/display records have seven-day retention. Capacity fails explicitly.
Pending deadlines are checked transactionally and by a deadline sweeper. Historical
blueprint audit files are not deleted. This capability is not yet a completed
legacy cutover: blueprint migration, remote-node/restart gates, retention cleanup
notifications and coordinated draining remain required before release.

## OpenShell artifact handoff v1

Native event executors declare `block_event.version = mn.block_events/v1` with
finite output ports and observation types. The runner environment advertises the
supported protocol; older runtimes cannot silently execute the new SDK binding.
Typed results carry immutable previous/next state identities, a result reference,
bounded emissions and optional isolated transport evidence. Core rejects unknown
ports/types, route/completion fields, oversized envelopes and stale transitions
before returning state/actions. Same-next replay is admitted with stable emission
idempotency keys. Ordinary default output routing is suppressed only for declared
event executors; Core retains logical-step completion. OpenShell transactions use
the physical message identity and include prior state in verified input admission.
Unversioned state requires a fresh run. The matching SDK/blocks event API is dev27.

Dev32-matched event workers require
`MN_BLOCK_EVENT_PUBLICATION_PROTOCOL=mn.published_files/v1`, supplied by Core
before execution. They may expose a verified publication manifest under
`publication`. Only after state/port/observation acceptance does the executor
deliver its files. Common references resolve from the trusted physical run;
isolated references resolve through the committed handoff graph. All receipts
and referenced bytes verify before any public name is replaced. Verification
captures bounded immutable bytes so later source changes cannot alter the copy.
The inventory permits at most 10,000 references / 64 MiB, within the existing
4 MiB event envelope bound. Destinations are confined to the actual run and
submission outputs, with canonical names and symlink rejection. Explicit file
names cannot use hidden top-level names, `blocks`, or `artifacts/results`;
worker publication cannot replace runtime state, locks, handoff receipts or
result pointers. File
permissions survive delivery; undeclared modes are private (0600), and the
stronger private policy wins for duplicate references. Required copy errors
remain retryable and preserve prior state. Optional copy errors produce Core
`block_publication_warning` events; invalid policies, unsafe paths and corrupt
files reject, even for optional files. Logical run files are always restored;
isolated configured-folder exports still require `artifact_handoff.export_outputs=true`.
Optional warnings use Core telemetry outside the ordered durable action list,
so repaired delivery cannot renumber business events or completion actions.
Same-next replay repairs delivery without
redispatching the SDK hook. A stale transition cannot publish. Individual file
replacement is atomic; the receipt is the complete-inventory barrier, not a
filesystem transaction across public filenames.

OpenShell selection remains per worker. Stock SDK block and auxiliary handlers require this
handoff; Core and SDK validation reject missing/conflicting modes before effects.
Core admits `mn.committed_json/v1` and `mn.committed_bytes/v1` inputs only from
the current physical run directory, verifies their complete referenced graph,
and promotes immutable copies into the private handoff input index. Traversal,
symlinks, identity conflicts and input count/byte quota violations fail closed.
`MN_RUN_DIR` and related paths always identify private sandbox storage.
`MN_BUNDLE_ROOT` is the private invocation workspace and
`MN_BLUEPRINT_MANIFEST_PATH` is its SDK-staged `runtime/manifest.json`;
inherited owner or image paths cannot replace these bindings. Canonical stock
workers resolve their exact compiled instances through that descriptor.
SDK `mn.block_handoff/v1` inventories expose every output file as an ordinary
handoff declaration while retaining original common reference identities for
SDK/domain consumers. Their outputs use the existing seal/transfer/receipt
transaction. Core does not import blueprint hooks or execute domain code while
admitting artifacts. HostLocal and Docker worker choices remain unchanged.

Private `MN_JOB_OUTPUT_DIR` points to `local/job-outputs`; it is distinct from
`MN_ARTIFACT_OUTPUT_DIR`, whose contents must all have declared handoff references.
Matching SDK dev31 publication turns logical output manifests into current
attempt/producer references under `exports`. Owner delivery remains an explicit
`artifact_handoff.export_outputs: true` policy. Successful receipt replay repairs
missing exported files after sandbox cleanup, without redispatching work.
`optional_exports` may name only unique declared export names (at most 10,000).
All references and paths verify before copying. Optional copy `OSError`s produce
`export_warnings`; required copy failures, bad policies, corrupt bytes and path
escapes remain failures. Temporary export files are removed on failure. The
`artifact_handoff.export_outputs` setting accepts only a boolean when present.

`artifact_handoff.version = "mn.artifact_handoff/v1"` selects an immutable
artifact protocol. It cannot coexist with `sync_shared_storage=true`; no error
falls back to whole-tree synchronization. Optional positive quotas are
`max_bytes` (default 64 MB), `max_files` (256), and `max_result_bytes` (1 MB).
`export_outputs=true` materializes the successful structured result's `exports`
map from committed references into the submission's configured output folder.

The runtime supplies the actual workflow run ID, logical step plus executor
instance, runtime attempt, owner identity and lease epoch. Core validates its
job lease before dispatch/publication and the owner store serializes publication
with a monotonic transaction fence. Identity or content conflicts fail closed.
Execution-start is synchronized before dispatch. Worker exit and bounded,
secret-redacted diagnostics are persisted independently of file transfer. Each
attempt has a distinct writable workspace. Cached inputs are job-scoped,
verified by size/hash, and copied into the attempt; sandbox recreation naturally
starts with an empty cache.

A worker declares files using SDK artifact references. The sandbox wrapper seals
all declared outputs and upstream result references after exit; the owner rejects
missing files, links, special files, unsafe paths, invalid producer identity,
quota excess, and hash/size discrepancies. Downloads are private staging files.
Only verified files enter a synchronized immutable directory; the receipt is
published atomically with that directory. Identical replay succeeds and a
conflicting receipt fails. Completion is emitted only after this receipt exists.
A transfer retry uses the recorded execution outcome, not another dispatch.

Artifact transaction receipts are a narrow exception to the prohibition on
recovering agent checkpoints from local disk: they recover the already completed
artifact publication, not agent memory or workflow coordination. Redis retains
workflow ownership and completion authority. On restart, maintenance reconciles
receipts against journals; executor replay returns the recorded result.
Uncertain dispatches without a trustworthy completion record are `unknown_blocked`
and require an explicit new run. Cleanup runs only after commit; failure leaves
a durable warning and is retried independently. The guarantee is owner-node
storage durability, without requiring another node's availability.

Deterministic acceptance coverage: `tests/unit/open_shell_artifact_handoff_test.exs`
uses the actual runner and both blueprint bindings; `tests/handoff/test_store.py`
exercises crash publication, fencing, conflicts, corruption, quotas and replication.

Child workflow start, plan-commit and round-complete events publish bounded
`topology_delta` step/edge metadata for the newly active planner or task DAG.
The projection excludes task inputs, outputs and artifact contents, allowing live
monitors to discover runtime-created steps without transferring large blobs.

## Running-time measurements

Run persistence maintains `running_time` (`accumulated_ms`, `active_since`,
`complete`) in durable records and live projections. Co-worker analysis exposes
these fields through the existing run JSON contract. Queue and pause intervals
are excluded; an interrupted coordinator session retains observed time and marks
unobserved recovery gaps incomplete. Historical records are not backfilled with
wall-clock estimates. No new gRPC method or protobuf fields are required.
Run projections expose `run_data_ref` with only the prepared submission ID,
physical workflow run ID and `syncthing` storage identity. This binds numeric
usage to the public execution while it is active, without exposing manifests,
host paths, inputs or output content. Missing/invalid identities omit the
reference; consumers must verify replicated run identity before reading usage.

## Manual durable checkpoint retry

- Failed runs expose `PlanRunRetry` and `RetryRun` in `mirrorneuron.job.v1`.
  Submission requires explicit overrides, expected attempt, checkpoint revision
  and an idempotency key. Core revalidates under the job lifecycle/start gate.
  Identical resubmissions return the accepted attempt; changed settings under
  the same key and stale selections are rejected.
- `mn.run_checkpoint/v1` records bind workflow-ledger v3 state to run/job IDs,
  attempt, immutable manifest/input digests, job-data generation and artifact
  integrity inventory. Redis remains the coordination authority. Unsupported or
  insufficient historical checkpoints are inspectable but cannot authorize retry.
- Completed steps/child tasks and dynamic graph state survive restoration.
  Unfinished steps restart from retained inputs; internal progress is restored
  only by declared durable domain contracts. Arbitrary process state is excluded.
  Missing boundaries or uncertain external effects block dispatch.
  Downstream steps skipped because a dependency could not succeed reopen on
  retry. Classification resolves and verifies staged skip outputs; missing or
  corrupt artifacts block retry. Intentional branch skips remain preserved.
- Accepted retry preserves job/run identity, increments attempt and lease epoch,
  clears current terminal output references and records failure, selected
  checkpoint, explicit changes and outcome in attempt history. Redis writes and
  shared completion markers are fenced against earlier attempts.
- Only declared retry-adjustable budget/connection fields accept explicit changes.
  Original bundle, topology and inputs remain unchanged. Durable active usage is
  preserved; failed waiting time is excluded. Per-invocation timeouts restart.
- Failed records and their checkpoint/bundle/artifact references outlive normal
  terminal retention until explicit deletion or data reset. Logs/delivery records
  remain bounded. Resource status exposes checkpoint count/bytes and artifact bytes.

OpenShell receipt replay uses the `mn.logical_request/v1:` request digest contract.
Matching Core-injected attempt/delivery/deadline fields are excluded from that
logical digest; user-supplied values and executable commands remain bound.
Older handoff receipts without this logical replay contract cannot authorize
checkpoint retry. Successful recovery retains its failed-attempt recovery records
until explicit deletion/reset, including when the latest attempt is completed.

## Durable job backup transport

`ExportJobBackup(JobRequest)` streams bounded `JobBackupChunk` files from a
quiescent stable job. `RestoreJobBackup(stream JobBackupChunk)` checks the complete
`mn.backup.v3` inventory and creates a fresh job definition with copied data.
Both RPCs require v1 requests, client identity, and runtime identity, and are
denied in network-only mode. Export follows the authoritative federated owner.

Snapshots include the archived bundle, persistent job data, retained run/event
history, artifacts, payload blobs, current staging and retained historical
staging. Start/resume is serialized with export. Source executions are preserved
as evidence under `.mn-restore/<source-job-id>` rather than replayed; schedules
receive fresh identities and remain paused. Restoring never overwrites an existing
job. The SDK owns ZIP64 transport, full offline wheels/images/models, host
compatibility and hardware preflight, and fresh native resource preparation.

The file protocol bounds chunks to 1 MiB, entries to 100,000 and uncompressed
content to 128 GiB; path, symlink, duplicate, inventory and checksum failures reject
restore. Earlier internal `mn.backup.v2` snapshots are not accepted by these RPCs.
Upgrade the generated SDK bindings and API/CLI adapters with Core.

HostLocal wheel capture and platform inspection use the existing native
`PrepareRuntimeModel` transport with `purpose=job_backup`. Core forwards these
Python requests without selecting a default model; the native SDK/CLI owns
execution-platform wheel builds and fresh offline virtual environments.

## Execution-node context service binding

DockerWorker binds Membrane endpoint, authentication, observability and serving
counter settings from the execution node as one service configuration before
launch. A submitter's credential cannot authenticate a different node's service.
Missing execution-node endpoint/authentication fails before dispatch. Secrets
stay in the trusted runner environment and are excluded from diagnostic output.

## Model residency across checkpoint retries

Checkpoint retries retain their run ID and use `MN_ATTEMPT_ID` for managed-model
ownership. Preparation, gateway requests, native records, and terminal cleanup
carry the same attempt identity. Finishing an attempt closes only its model
references; a later attempt can prepare the model without reopening the old
attempt. Delayed cleanup and garbage collection cannot release a later
attempt's model. Unversioned callers keep their existing run-scoped fences.
Upgrade Core, the native SDK, gateway callbacks, and prepared worker SDKs
together; saved worker images keep the SDK version with which they were built.

## Standard runtime activity

Runtime events use the shared [`mn.runtime.event.v1` contract](../mn-python-sdk/docs/runtime-activity.md),
including level, blueprint owner, UTC timestamp and actor attribution.
The SDK selects meaningful activity for the CLI, API, desktop and web monitors;
raw events remain available for diagnostics.

Prepared Job detail projections include the public `mcp` supervision declaration
and staged manual/hash from the definition manifest. Summary projections omit
it. Private environment fields are never projected. Execution remains owned by
Core; API and SDK supervision adapters do not infer completed transitions.

Checkpoint artifact helpers have a 60-second execution bound. Within one inspection, identical complete artifact descriptors share verification; distinct descriptors and subsequent inspections retain independent hash, size, confinement, receipt and replay checks. A failed integrity capture still blocks checkpoint retry.


## Exclusive run admission per PC

The owner Core admits at most one active run per physical PC, including CPU-only
runs. Its durable node claim reserves CPU, memory and all advertised GPUs for the
run identity. Several workers and models reuse that claim. Different PCs advance
independently. Resource requirements still validate hardware fit; GPU count is
not multiplied by the number of models in one run.

Starts atomically join the owner-local FIFO or claim the idle PC through a Redis
version compare-and-set. An accepted busy start returns `status: queued`, an
`admission` receipt with `queue_id`, `owner_node`, friendly node label, queue
position and blocker, and no execution PID. It starts automatically without
confirmation. Existing queued work cannot be bypassed. Queued requests retain
their physical run ID, stable job, manifest, staged inputs, configuration hash,
bundle fingerprint and data generation. Repeated starts use the existing
idempotency identity. Reconciliation repairs requests persisted just before a
queue-write interruption.
Keyed start intents and receipts are stored in Redis before acknowledgement;
their hashes and selected run identity survive owner restart. A committed run
whose receipt write was interrupted is reconciled only when its manifest bears
that same request identity. Changed payloads or unrelated run IDs remain conflicts.

`MirrorNeuron.Runtime.NodeAdmission` owns dispatch, reconciliation and monotonic
fencing generations; `NodeAdmissionState` owns deterministic transitions. State
is stored at the owner under the node-admission namespace. Availability snapshots
never grant admission. Remote starts use authenticated federation and require
`exclusive_run_v1`; the owner also requires that capability from its native SDK.
Workers, managed models, embeddings and model fallback stay on that PC. Hosted
API providers remain supported. Native worker and inference gateways check the
claim and generation. Model engines load only after admission and cold model
loads check live available memory. Definition preparation creates inactive worker
containers and stages Compose projects. Cached model artifacts are retained.

Pause, automatic retry, and recovery retain ownership. The claim is released only
after a terminal run has stopped commands/containers, drained native inference
leases and released run-owned GPU residency. A missing process, timeout, owner
partition or stale advertisement cannot release it. Pre-existing distributed
runs remain protected on their participating nodes through confirmed cleanup.
Explicit checkpoint retries reacquire the same PC or wait in its FIFO queue.
Queued retries preserve their checkpoint selection and idempotency receipt;
dispatch verifies the checkpoint and original inputs again before a new attempt.

The node queue is projected as `resource_wait` schedules named `queue_<run_id>`.
`ListSchedules`, `GetSchedule`, `UpdateSchedule`, and `DeleteSchedule` expose these
through the authenticated Job service. Deleting a queue schedule cancels only an
unstarted execution. Updating `run_at` defers that same execution until a future
ISO timestamp; it holds no resources and joins FIFO when due. Revision checks and
the admission start gate protect cancellation/scheduling races. Scheduled
occurrences use the same queue and preserve occurrence deduplication/overlap
rules. Changed definitions, revoked owner credentials, or missing inputs fail for review and allow the next
entry to advance after cleanup. Queue and claims survive client/owner restart.

Roll out Core and the native SDK together. Before deployment, run the opt-in real
two-PC check: A runs on Spark; B queues there; C runs on the other PC; B starts
exactly once after A's cleanup. Source/unit verification does not substitute for
that hardware smoke test or authorize a deployment.

## Workflow action allowance protocol

`policies.workflow_budgets` contains one to 32 named compiled `{limit: integer}`
allowances, each from zero to 100,000. The canonical SDK resolves authored
configuration references before submission. `SetResource` operation
`workflow_budget`, schema `mn.workflow_budget/v1`, requires authenticated client
identity. Its closed start/complete/summary commands bind the Job, actual
workflow run, allowance name/limit and stable request scope. It never changes
physical resource percentages or node-admission state.

The job coordinator registers an allowance owner under the stable Job ID and
actual workflow run ID before starting workers. Resource commands resolve that
exact pair, independently of the execution ID used by ordinary coordinator
controls. The registration follows coordinator lifetime and is restored on
checkpoint retry; another Job or workflow run cannot share its allowance.

The registered job coordinator serializes admission. It rejects stopped/paused
owners, mismatched runs, undeclared or changed limits, malformed requests and
invalid accounting. New starts and completions are persisted through the existing
fenced job snapshot/replica barrier before acknowledgment. Persistence failure
cannot grant work. Successful replay returns the original reservation; a changed
request or completion rejects. Unknown starts remain charged and completion does
not refund capacity. Pool state is restored for checkpoint retry and cannot be
silently reused by a new run. Summary reads observe one coordinator snapshot.

Each allowance journal has at most 100,000 records and 4,000,000 encoded bytes;
individual metadata objects are bounded to 16 KiB. Capacity rejection occurs
before another grant, with no truncation or hidden reset. These are action units,
not monetary billing or a provider retry mechanism. Native model/tool effect
journals, leases and Core delivery remain responsible for dispatch safety.
SDK/blocks dev30 and this Core protocol must be rolled out together. Current
verification uses offline owner transitions, synthetic transports and fake
OpenShell sandboxes; it does not authorize a live deployment.

The public workflow definition preserves the bounded, SDK-compiled
`workflow.service_lifecycle` contract (`mn.service.workflow.v1`), containing
startup/service/shutdown phase assignments and required monitored services.
It remains a presentation contract: serving does not complete ledger steps.
