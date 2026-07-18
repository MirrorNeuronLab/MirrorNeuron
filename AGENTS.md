# AGENTS.md

Instructions for coding agents working in this repository. These instructions
apply only to `MirrorNeuron` Core.

## Start Here

1. Read `SPEC.md`, then the relevant parts of `README.md`.
2. Read the touched module, adjacent modules, and the closest unit/E2E tests.
3. Check `git status` and preserve unrelated work.
4. Confirm the change belongs in Core. Product-specific agents, Python
   compilation helpers, CLI rendering, REST adaptation, and domain workflows
   belong outside this repository.

Core is an Elixir/OTP runtime. Prefer small, idiomatic changes using explicit
messages, pattern matching, supervision, and stable data contracts.

## Architecture Boundary

Core owns workflow execution, supervision, physical routing, delivery,
persistence, clustering, scheduling, resource admission, runner selection, and
gRPC services. Isolated or domain execution happens through runners and staged
payloads; do not embed blueprint business behavior in Core.

Important paths:

- `lib/mirror_neuron.ex`: public runtime/control facade.
- `lib/mirror_neuron/application.ex`: OTP startup and supervision.
- `lib/mirror_neuron/manifest.ex`, `job_bundle.ex`, `bundle/`: executable
  manifest and bundle loading.
- `lib/mirror_neuron/runtime/`: job lifecycle, delivery, workflow ledger,
  backpressure, deployment, scheduling, recovery, and reliability.
- `lib/mirror_neuron/builtins/`: generic routing/execution/step boundaries.
- `lib/mirror_neuron/agent_templates/`: generic agent process templates.
- `lib/mirror_neuron/persistence/`, `redis/`: durable state, snapshots,
  retention, and Redis HA.
- `lib/mirror_neuron/cluster/`: membership, leadership, draining, and repair.
- `lib/mirror_neuron/runner/`, `sandbox/`, `execution/`: host, Docker,
  OpenShell, sandbox, upload, and lease boundaries.
- `lib/mirror_neuron/artifacts/`: job artifacts and shared storage.
- `lib/mirror_neuron_grpc/`, `proto/`: public gRPC handlers/contracts.
- `config/`: defaults and runtime environment validation.
- `tests/unit`, `tests/e2e`, `tests/api`: layered ExUnit coverage.

## Runtime Invariants

- Validate and normalize manifests before scheduling or starting work.
- Avoid oversized runtime and persistence modules. New behavior must live in a
  cohesive module with a clear domain boundary; split mixed concerns before
  extending a large legacy module, preserving public module contracts through
  narrow delegating facades where needed.
- Only generated/owning step boundary controls complete logical steps.
- Keep coordination messages bounded, explicit, and serializable. Large or
  sensitive results are durable artifacts referenced by messages.
- Preserve message identity, TTL, lease, ACK, retry, deduplication, and
  dead-letter semantics. A retry must not duplicate externally visible work.
- Persist lifecycle changes and publish corresponding events consistently.
- Scope locks, queues, supervisors, and cleanup to the job/agent/resource they
  protect; unrelated jobs must continue making progress.
- Recovery must reject unsafe or incompatible state rather than guessing.
- Control-node forwarding and local execution must expose equivalent public
  results.
- Keep resource admission and runner policy explicit. Do not bypass isolation
  or broaden OpenShell/network policy to make a test pass.
- Treat manifests, paths, environment values, runner output, Redis data, gRPC
  requests, and remote-node data as untrusted.

## OpenShell and Runner Safety

- Put blueprint-specific system packages and network rules in the blueprint's
  custom image/policy, not the Core image.
- Private/LAN access needs exact hosts/ports and scoped `allowed_ips`; do not
  broadly permit RFC1918 ranges.
- Policies list the resolved executable and any required launcher. Diagnose
  denials from sandbox logs before widening a rule.
- Plain HTTP clients may need narrow TCP passthrough rather than REST inspection
  when they do not use CONNECT.
- Cleanup only sandboxes, processes, uploads, and leases owned by the job.

## Where to Start

- Manifest/bundle: `manifest.ex`, `job_bundle.ex`, `bundle/`,
  `tests/unit/manifest_test.exs`, `blueprint_validation_test.exs`.
- Lifecycle/delivery: `runtime/job_coordinator.ex`, `job_runner.ex`,
  `agent_worker.ex`, `delivery.ex`, `workflow_ledger.ex` and matching unit tests.
- Persistence/recovery: `persistence/`, `runtime/local_recovery.ex`,
  `recovery_safety.ex`, backup/recovery tests.
- Cluster: `cluster/`, `distributed_registry.ex`, `rpc.ex`, cluster tests.
- Runners/sandbox: `runner/`, `sandbox/`, `execution/lease_manager.ex`, runner
  and cleanup tests.
- gRPC: `lib/mirror_neuron_grpc/`, `proto/`, API/gRPC handler tests. Update proto
  sources and regenerate bindings together when the wire contract changes.

## Change and Verification Workflow

- Add focused success, failure, lifecycle-transition, and recovery tests for
  meaningful changes.
- Public manifest, gRPC, config, event, message, or persistence changes require
  compatibility review and updates to `README.md`/`SPEC.md` as applicable.
- Do not add dependencies without a clear Core-level need.
- Do not hand-edit build artifacts or generated protobuf files without their
  source change/regeneration path.

Run:

```bash
mix format --check-formatted
mix test
mix compile --warnings-as-errors
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Redis-backed and live cluster/OpenShell tests may need external services; keep
ordinary unit tests deterministic and report unexercised integrations.

## Issue-Fixing Policy

- Fix the root cause in the owning runtime contract unless the user explicitly
  requests a temporary workaround.
- Do not add fallback paths, shims, or flags that hide a broken primary path.
- Keep product-specified compatibility behavior narrow, documented, and tested.
