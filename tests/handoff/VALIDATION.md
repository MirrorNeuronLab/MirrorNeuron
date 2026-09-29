# Artifact handoff validation — 2026-09-28

## Deployment

The local Core image `mirror-neuron-core:artifact-handoff-v1` was deployed as
`mirror-neuron-core:latest` and verified running with image identity:
`sha256:0c94a324f8ea97fee3bc17752bd5ad1bee7ebefca0868ba44798fa083f15525f`.
The deployed runner, workflow-environment helper, and Python transaction store
hashes match the workspace sources. The SDK is loaded from the local SDK checkout;
submission preparation bundles that source into worker images. This is a local
source rollout, not a published GAR release. Release deployments must package
this SDK capability with Core; the old SDK alone cannot run migrated workers.
The prior Core image is retained as `mirror-neuron-core:before-artifact-handoff`.

## Automated verification

- 17 focused Core tests: actual OpenShell runner with deterministic transports,
  immutable publication, sandbox replacement, replay without sandbox, transfer
  retry with one invocation, unknown dispatch blocking, cleanup failure, combined
  execution/transfer failure, both blueprint workers, runtime run-ID propagation,
  and exclusion of mutable staging/journals from the completion inventory.
- 14 existing DockerWorker regression tests passed with Core services started.
- 52 SDK/store tests: reference integrity, missing/corrupt bytes, delayed replica,
  unsafe paths/types, producer mismatches, quotas, stale epochs, conflicting and
  duplicate commits, interrupted publication, concurrent immutable JSON writes,
  SDK dependency preparation and compatibility behavior.
- 27 demo, SDK step-runtime and host event-relay tests passed, including physical
  run-ID resolution during host delivery.
- 35 advisor tests passed; 2 existing skips. These cover serial task admission,
  reservation retention after interruption, bounded prompts, committed review
  reconciliation, report validation and exports without SQLite. The 10 catalog
  tests were rerun after the report export change and passed.

Crash recovery tests simulate durable states before/after publication and before
completion replay. No destructive live crash-injection or owner-storage-loss test
was performed. Full repository test suites were not run. The repository-wide
format check fails on existing unrelated files (including interaction-store and
job-projection tests); strict compilation fails on existing redundant-clause
warnings in RedisStore/runtime. Changed Elixir files are formatted; diff checks
and shell syntax checks pass.

## Bounded live checks

| Run | Outcome |
| --- | --- |
| `handoff-demo-smoke3-20260928` | One live OpenCode invocation timed out at 120 seconds. Its worker error was committed; verification did not run. |
| `handoff-demo-deterministic-20260928` | Completed through the real Core/OpenShell gateway using a temporary blueprint copy with a deterministic generator. Both steps committed; four files exported to `/tmp/mn-handoff-live-demo-export`. Export replay did not rerun workers. |
| `handoff-advisor-smoke2-20260928` | One review reached the provider and received HTTP 403. The failure was committed and its reservation retained. No automatic retry or model fallback. |
| `handoff-advisor-offline2-20260928` | Explicit offline mode, one task, one round. Completed on real OpenShell; owner reconciled the committed task result and exported report/sections/JSON audit to `/tmp/mn-handoff-advisor-offline-export`. Host delivery receipt reports success. |

Early smoke attempts also found and corrected missing SDK staging, the sandbox
Python interpreter selection, and definition-label versus physical run-ID
propagation. They failed before model execution. Smoke exports used temporary
folders; the demo's normal default remains `~/Download/demo_openshell_code_generation`.

## Operational semantics

Transfer retries do not dispatch a worker. A receipt can be replayed without the
sandbox; startup maintenance repairs the transaction journal and retries cleanup.
Workflow replay, rather than maintenance independently editing the workflow
ledger, recovers step completion. Unknown execution requires an explicitly started
new run; there is no force-rerun switch for an existing transaction. Lease checks
use the runtime epoch plus the serialized owner transaction fence. Filesystem and
Redis state are reconciled rather than represented as one cross-store transaction.
Owner durable storage loss remains outside the guarantee.
