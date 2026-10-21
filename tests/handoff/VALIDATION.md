# Artifact handoff validation — 2026-09-28

## Native catalog and optional OpenShell — 2026-10-20, current checkpoint

All thirteen catalog blueprints pass the native block gate. The full offline
catalog run passes 1,378 cases with 29 skips and 37 dependency warnings. The
26-case OpenShell selection gate covers existing bindings and opt-in settings
across all thirteen packages, preserving the original worker choices, topology
and compiled hooks. Selected compatible workers use the shared SDK/Core handoff;
blueprints supply their images and scoped policies.

SDK CI passes 3,571 cases with its existing 95% component-coverage floor (95.09%
measured); blocks pass 473 cases with their existing 90% floor (95.16% measured).
The focused Core event, actual-runner, artifact-handoff and environment gate
passes 28 cases. A separately installed main SDK dev34 / blocks dev33 / common
dev30 candidate also passes the actual Core event-runner test, including sandbox
replacement, no early public copy and receipt replay after cleanup.

The installed CCTV CLI probe executes all four compiled native workers in fresh
processes, then replays each without a second claim, model call or completion
RPC. It prepares real JPEG/MP4 bytes while substituting only resident/model
transports, and verifies excluded private model reasoning, immutable input
evidence and accepted report publication. Main SDK dev34 additionally preserves
typed peer artifact references during native event admission and journals raw
multimodal model responses before interpretation.

The packaged blueprint Python audit is 58,600 to 52,411 lines (-10.6%), and 548
to 375 files. It includes staged copies and the retained Litigation (+83 lines)
and ROS (+10 lines) domain integrity/completion hooks. Shared dependencies,
repository tests, documentation and generated files are excluded.

These are source/test candidates, not releases or live qualification. No gateway,
provider, camera, GPU or robot was exercised, and no deployment, tag, commit or
push was performed. Core's global strict compile still encounters the existing
redundant RedisStore clauses described below; the affected contract tests pass.
Global formatting also rejects four interaction files, all byte-identical to
`HEAD`; formatting passes for all 19 changed Elixir files. Shell syntax and
`git diff --check` pass. No unrelated formatting changes were applied.
Earlier checkpoints record their historical source states.

## Accepted event publication — 2026-10-20, earlier checkpoint

Matching SDK/blocks dev32 source verifies `outputs.published_files` and returns its
manifest without materializing public names. Core advertises publication support
before hooks run. The executor accepts the exact state transition before its
standalone helper verifies receipt plans, all bytes and owner paths, then copies
to logical run files and permitted output storage. Stale transitions cannot
publish. Explicit isolated export policy, required/optional delivery and file
permissions remain enforced. Optional warnings use telemetry outside ordered
durable actions, so repair cannot change their identities. Bounded verified bytes
are retained through copying to prevent a later source mutation changing output.

Offline gates pass: 53 Core owner/auth/event/runner/environment cases and 91 Python
handoff cases. The new publication helper has 55 cases / 93% branch coverage.
The actual executor tests stale rejection, optional-copy repair, stable action
shape and disabled folder export. The real OpenShell runner with a simulated
transport proves no early public copy and replay after sandbox cleanup with one
domain call. That runner also passes against separately installed SDK/blocks
dev32 test wheels plus common dev30, with loaded module-path assertions.
SDK CI passes 3,510 cases at 95.09% coverage; blocks pass 422 at 95.13%, preserving
their existing 95% and 90% floors. These dev32 versions are explicit test-build
overrides, not releases; the underlying SCM base remains dev26.
Both SDK and Core reject public names in hidden top-level namespaces, `blocks`
and `artifacts/results`, before rendering/copying. Untrusted output declarations
cannot replace owner runtime records or handoff receipts.

CCTV v5.1 ingress is native; its other three event workers remain. Its installed
CLI probe preserves start/steering replay after deleting a synthetic source.
The 229 CCTV/catalog composition/selection cases pass; the strict native catalog
gate remains twelve of thirteen. Core's required strict compile still fails on
existing redundant RedisStore clauses; no new module warning is reported.
This checkpoint was not deployed or qualified against a live gateway, GPU,
camera or model, and it created no release, tag, commit or push.

## Native publication and optional runner — 2026-10-20, earlier checkpoint

OpenShell remains an explicit per-compatible-worker choice. Selected stock SDK
block workers use the same versioned handoff, verified private input graph,
compiled descriptor and Core completion contract. Existing runner defaults stay
intact. Main SDK dev31 publication separates private logical output files from
registered wire outputs and declares required/optional exports. Core validates
the complete inventory before delivery; optional copy failures qualify the
result, required copy failures reject, and receipt replay repairs missing files
after sandbox cleanup without another domain invocation.

Offline checks pass: 52 Core owner/auth/runner/environment cases, 36 Python
handoff cases, 3,501 SDK CI cases and 413 block cases. The actual Core runner
fixture demonstrates required delivery, optional-copy failure, sandbox cleanup
and repair on replay with one domain invocation. The separately installed
twenty-one-role VC CLI probe verifies full publication and replay with synthetic
models and a synthetic budget owner. Its main SDK dev31 wheel is an explicit
test-version candidate; the checkout's SCM base is dev26, and no release/tag was
created. The strict native catalog gate is now twelve of thirteen, with CCTV's
four event workers remaining. No live gateway/provider/policy installation,
deployment, commit or push was performed for this checkpoint. Earlier deployment
records below describe earlier source states, not this change.

The current SDK/Core guard also covers auxiliary-service bindings, which delegate
to the same shared worker. Offline regression gates pass with 90 SDK transport/
service cases, 27 Core runner/event/environment cases, and 39 catalog composition/
optional-selection cases across all thirteen packages. Missing handoff rejects
before staging or dispatch for both handler types. This does not make a
camera/device service compatible with arbitrary images or sandbox policies.

## Optional runner standard — 2026-10-20, earlier checkpoint

Blueprints select OpenShell per compatible worker; existing runner defaults
remain intact. Selected stock SDK block workers require artifact handoff v1 and
retain their compiled hooks, descriptor and Core completion semantics. Private
input restoration and nested artifact publication use the shared SDK/Core path.

The focused offline checks pass: 26 catalog selection/composition cases across
all thirteen packages, 60 SDK handoff/descriptor cases, eight Python Core handoff
cases and 14 actual Core runner/environment cases with a fake OpenShell CLI.
Replacement sandbox, cleanup/replay, interrupted transfer and uncertain dispatch
cases are included. No live gateway, provider or policy installation was exercised.
The strict native catalog migration remains eleven of thirteen; VC and CCTV are
still incomplete. Earlier checkpoints below describe their recorded source state.

## Canonical block descriptor and native context — 2026-10-20 follow-up

The SDK stages the resolved descriptor with both DockerWorker and OpenShell
selected uploads. Core binds `MN_BUNDLE_ROOT` and `MN_BLUEPRINT_MANIFEST_PATH`
to the private invocation, replacing inherited owner paths. An actual compiled
stock block now executes through the Core runner and replays after sandbox removal
with one domain invocation. No blueprint transport wrapper is required.

Current offline checks: 12 actual runner tests using a filesystem transport double;
29 Core filesystem/SDK boundary tests; 262 SDK/component/compiler/runtime tests;
147 Architecture Advisor tests with 24 existing dependency skips. The SDK and
block wheels build with the native-context service and shared transport present.
Architecture Advisor's native conversion reduces production Python from 9,241 to
7,158 lines. The strict catalog native gate is 8/13; CCTV, Litigation, VC,
Microduck and CT still require native conversion. OpenShell selection remains
optional. This follow-up has not been deployed or live-qualified.
The combined catalog check reports 93 passed and five failures, exactly those
remaining native-conversion gates; all 85 other catalog checks pass.

## SDK block integration — 2026-10-20 (workspace source)

OpenShell remains optional. Selected stock block workers share the private Core
handoff instead of implementing blueprint transport wrappers. Architecture
Advisor's packet reviewer now uses the direct native hook and stock SDK worker.
This update has not been deployed or live-qualified.

Offline checks: 11 actual Core runner tests with a filesystem transport double;
29 Core filesystem/SDK boundary cases, including host → two replacement isolated
workers → host, nested JSON/bytes, stock report publication, artifact integrity,
quotas and receipt recovery; 99 focused SDK/compiler/submission/runtime cases;
26 catalog composition/optional OpenShell cases; 162 Architecture Advisor cases
with 32 existing RGX/browser dependency skips. The SDK wheel builds and contains
the new transport. Existing catalog native-migration gates remain 7 passing and
6 incomplete; this integration does not claim completion of all 13 migrations.

The owner resolver accepts an explicit trusted physical run ID so reconciliation
can read an admitted run's receipts after the current runtime identity changes.
Verification caches are scoped to a single inventory read. No live provider,
gateway, policy provisioning, GPU or device operation was exercised.

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
