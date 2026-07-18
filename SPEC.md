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

A submitted bundle is loaded, normalized, validated, checked for services and
requirements, admitted to resources, and started under per-job supervision.
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

Job and agent lifecycle transitions are validated and persisted. Terminal job
states are completed, failed, or cancelled. `cancelling` is a fenced,
non-recoverable transition: durable cancellation intent revokes the old lease,
rejects stale coordinator/agent writes, and prevents recovery, resume,
scheduling, and drain migration until locally owned cleanup is acknowledged.
Pause, resume, cancel, backup, restore, deployment, and schedule operations
preserve event/status coherence.

Fixed server-defined group-operation kinds persist their immutable target
snapshot, item states, counters, errors, timestamps, and replayable progress
events in Redis. OTP-supervised runners apply bounded unordered concurrency;
unfinished work is resumed after a Core restart. A request is successful when
durable cancellation intent has been committed even when remote cleanup remains
pending.

Redis is the primary durable coordination store. Disk checkpoints and shared
artifact storage supplement declared recovery paths. Recovery verifies runtime
identity, bundle compatibility, ownership, and safe state before resuming.
Retention removes only eligible terminal/history data according to configured
policy.

## Cluster and Resources

Core uses OTP distribution, `libcluster`, and Horde-based runtime coordination
for clustered operation. Membership, leader/control forwarding, node state,
draining, reconciliation, and network-only nodes are explicit. A control-node
call must preserve the public result of the same local operation.

Scheduling and admission consider declared CPU, memory, GPU, services, models,
node state, and execution profiles. Lack of an admissible placement returns an
actionable failure; it does not bypass requirements.

## Execution and Isolation

Runner policy selects host-local, Docker, or OpenShell execution according to
the executable manifest/profile. Core stages bounded inputs, passes explicit
environment/config, captures a structured result, registers durable artifacts,
and cleans up only owned resources.

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

## Compatibility

Breaking changes include manifest semantics, protobuf fields/service behavior,
message/event shapes, lifecycle transitions, persistence keys/formats, default
delivery policy, runner policy, or configuration precedence. They require a
versioned migration/compatibility path and tests. Additive optional fields are
compatible only when omitted behavior remains unchanged.

## Acceptance

```bash
mix format --check-formatted
mix test
mix compile --warnings-as-errors
```

Shell scripts also pass `bash -n`. Unit tests cover deterministic behavior;
Redis, OpenShell, Docker, and multi-node paths receive focused integration/E2E
coverage when those contracts change.
