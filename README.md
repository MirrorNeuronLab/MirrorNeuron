<h1 align="center">MirrorNeuron 🧠</h1>

## Activity-supervised workflows

`workflow.execution.supervision: "activity"` uses live SDK progress and process
heartbeats instead of an implicit batch elapsed deadline. Core requires HostLocal
executor nodes with enabled, required agent beacons; buffered runners are rejected.
An explicit step or runner `timeout_seconds` remains an intentional hard budget.
Existing workflows without this declaration retain their deadline semantics.

A step may run for any total duration while its progress sequence advances.
Automatic process/runtime beacons only establish liveness. Core tracks progress
per physical worker, rejects duplicate counters, and fails a step after five
minutes without progress with `workflow.step.progress_timeout`. Missing heartbeats
retain their existing failure and cleanup behavior. A bounded SDK external wait
carries a stable identity and allowance (at most one day); repeated beacons cannot
extend that wait. Pause excludes paused time from the progress clock. Progress,
wait identity and expiry survive persisted-ledger recovery. Only the owning step
boundary can commit completion; late heartbeats cannot revive terminal work.

Deploy matching Core, SDK and common components on every execution owner, then
reprepare saved Job definitions before launching new work. Existing failed or
running definitions and retained retry checkpoints are not rewritten.

<p align="center">
  <strong>Durable AI workflows on your own machines.</strong><br>
  Package the work. Run it. Inspect every step.
</p>

<p align="center">
  <a href="https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/index.md">Documentation</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/examples.md">Examples</a> ·
  <a href="#develop-core">Contribute</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-22C55E?style=flat-square" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Runtime-Elixir%2FOTP-6E4A7E?style=flat-square&amp;logo=elixir&amp;logoColor=white" alt="Elixir/OTP runtime">
  <img src="https://img.shields.io/badge/State-Redis-DC382D?style=flat-square" alt="Redis-backed state">
  <img src="https://img.shields.io/badge/Status-Beta-F59E0B?style=flat-square" alt="Beta status">
</p>

MirrorNeuron is a runtime for AI workflows that need more than a model call:
multiple agents, long-running work, reusable configuration, recoverable
execution, and results you can inspect. Start on one machine and federate
trusted machines when you need more capacity.

**This repository contains MirrorNeuron Core**, the Elixir/OTP engine that
schedules work, supervises agents, persists runtime state in Redis, and exposes
gRPC control and observability. The CLI, Python SDK, REST API, and Web UI build
on that engine.

> [!IMPORTANT]
> MirrorNeuron is in beta. This README follows the current source documentation;
> installed releases may differ. Check `mn --version` and command help when
> following a guide, and use compatible ecosystem releases.

Child-round plan nodes accept an optional non-empty `label` of at most 1,024 UTF-8 bytes. Core persists it on the child instance and includes it in public topology events; omitted labels retain the template label or instance ID. Labels do not alter task identity, dependencies or execution.

## Why MirrorNeuron?

OpenShell workers synchronize shared outputs before cleaning their invocation
workspace. Failed transfers preserve the sandbox copy for recovery.

Verified event publications and enabled isolated exports also maintain a portable
public-file inventory for SDK/API downloads. Terminal shared runs request a
Syncthing scan of their own committed output subtree so Docker writes replicate
promptly. Use matching Core and SDK sources for this delivery contract.
The public inventory remains readable to the host sync process under Core's
restrictive umask; private handoff receipt permissions are unchanged.

Agent workflows become harder to operate when they span many steps, wait for
input, call external services, or need to survive a restart. MirrorNeuron gives
that work an explicit execution model and a durable record of progress.

| Capability | What it gives you |
| --- | --- |
| **Reusable blueprints** | Package a workflow with its configuration, input/output contracts, worker code, and dependencies. |
| **Durable jobs and runs** | Keep a configured definition and its execution history; inspect, pause, resume, or cancel an individual run. |
| **Observable execution** | Follow workflow steps, events, logs, and output artifacts through the CLI and Web UI. |
| **Bounded adaptive workflows** | Use branches, parallel steps, scatter–gather, and declared dynamic regions or child workflows under runtime-enforced limits. |
| **Resource-aware execution** | Select an eligible owner using declared hardware, model, and service requirements, then admit work locally. |
| **Recovery controls** | Use supervision, durable delivery, leases, and retry policies, with operator review when replay is unsafe. |
| **Local and configured remote models** | Route model calls through the job owner's LiteLLM gateway, with Docker Model Runner for local inference. |

See [Why MirrorNeuron](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/why-mirrorneuron.md)
for workload fit and the
[reliability guide](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/reliability.md)
for guarantees and limits.

OpenShell buffers command output until completion, including artifact-handoff
workers. Its inherited node beacon timeout does not shorten a workflow task
deadline. Explicit workflow heartbeat controls remain authoritative; otherwise
the declared step timeout governs both fixed and child tasks.

## How it works

```text
Blueprint package
  workflow + execution + contracts + configuration + payloads
                             │
                      SDK validation
                       and compilation
                             │
                      Durable job definition
                             │
                        Run on owner Core
                             │
                 Workflow ledger and scheduler
                             │
                 Agents through declared runners
                             │
                     Events, logs, artifacts
```

A **blueprint** packages reusable work. The SDK validates and compiles its source
into an executable **bundle**. A **job** stores the durable configured definition;
a **run** identifies an execution of it. Use the public job ID for definition
operations and the public run ID for execution controls, logs, and results.

New generated run IDs use the job's initials and a fresh eight-character hex
suffix, for example `job_cv-baa84224` → `run_cv-a1b2c3d4`. Idempotent starts
persist that compact ID separately from their full internal request hash.
Existing IDs and explicitly supplied run IDs keep their original values.

Batch jobs can retain multiple runs. Service jobs retain at most one attached
run, and pause/resume preserves that identity. Retries belong to the same run
and have their own attempt identity.

Blueprint authors declare the logical workflow separately from worker execution.
Core owns scheduling and completion boundaries; agents and skills own task
behavior. Dynamic workflows can instantiate admitted templates within declared
bounds. They cannot arbitrarily rewrite running work.

Child plans (execute and stop) are limited to 128 KiB of compact UTF-8 JSON,
including task metadata and immutable artifact references. This accommodates
the admitted 128-step ceiling; large inputs and results remain in shared files
replicated by Syncthing. Older Core builds enforce 32 KiB, so deploy the matching
Core before submitting larger plans. Task and round limits are unchanged.

Read [Core concepts](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/core-concepts.md),
[Blueprint format](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/blueprint-standard.md),
and [Runtime architecture](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/runtime-architecture.md)
for the full contracts.

### One owner per job, independent machines

Each federated Core has its **own writable Redis**. A job and all of its workers
stay on one owner Core. Peers exchange authenticated gRPC requests and cached
job/run summaries; federation does not require shared Redis or a Distributed
Erlang cluster.

Owner-forwarded Job creation and executable-bundle replacement allow up to two
minutes to persist payloads and initialize Job data. Metadata-only updates,
ordinary reads, and connection setup keep the usual 15-second deadline. The
SDK allows 130 seconds for the corresponding definition submission, including
the owner's reply, and does not retry creation automatically.

Native SDK unary calls release their gRPC connections after each command,
including failures. If retirement of a previous definition's native resources
fails after a replacement commits, the replacement response retains its saved
revision and reports `resource_cleanup_errors`. These bounded records contain
the owned identities and `native_resource_cleanup_failed`, without raw command
diagnostics. The existing resource cleanup lifecycle can retry retirement.

Federated unary calls reuse authenticated HTTP/2 connections. Concurrent setup
is coalesced per peer, local identity, endpoint, and credential digest; the pool
holds at most 64 connections and 1,024 active or waiting requests. Idle channels
expire after five minutes. Credential or endpoint changes and transport failures
retire a channel after its current requests finish. Failed requests are never
replayed by the pool, and operation deadlines and durable review checks remain
unchanged. Streaming calls and independent peer probes retain their own channels.

```text
CLI / REST API / Web UI
          │
          ▼
   Core A + Redis A ◄── authenticated federation ──► Core B + Redis B
          │                                               │
     A-owned jobs                                    B-owned jobs
     local workers                                   local workers
```

Scaling means running independent jobs on eligible owners. A peer connection
failure does not transfer ownership: the owner can continue its local work,
while remote summaries may become stale. Federation does not automatically
migrate an unavailable owner's jobs.

Federated peer status uses an authenticated gRPC reachability check every five
seconds. Three consecutive failed checks mark a peer unavailable; one successful
check restores healthy status. Job and run summary refreshes run separately, so
a refresh failure marks cached summaries stale without changing peer status.

Model routing follows the same owner boundary:

```text
Local model:   worker → owner LiteLLM → owner Docker Model Runner
Remote model:  worker → owner LiteLLM → peer LiteLLM → peer Docker Model Runner
```

The Core image pins LiteLLM 1.100.1 with a reviewed build-time usage
normalization correction. Streaming provider counts, including reasoning and
cache details, survive gateway forwarding without extra counting requests.
The build verifies the upstream source hash and exercises real streaming
parsing against a local synthetic server. Rebuild the gateway image after
upgrading Core source; source sync alone does not change its installed library.

See [Federation architecture](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/cluster_architecture.md)
and [Model runtime](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/model-runtime.md).

## Get started

### 1. Install and start the runtime

Use macOS, Linux, or Windows with WSL2, with Docker installed and running.
The checkout-based installation below also needs Git. Docker Model Runner is
needed when your chosen blueprint requires local models; there is no universal
model prerequisite.

From a directory where you keep projects, clone the deployment tools and review
`install.sh` and its options before running it. The installer installs the
selected runtime components and local support files.

```bash
git clone https://github.com/MirrorNeuronLab/mn-deploy.git
cd mn-deploy
./install.sh --help
./install.sh
```

Then, from any directory:

```bash
mn --version
mn runtime start
mn runtime status
mn node list
```

Startup should report `Runtime node ready`; resolve failed required health
checks before submitting work. Startup also prints a federation join credential:
keep it private. Use `mn runtime doctor` for diagnostics.

The default installed endpoints are:

| Surface | Default |
| --- | --- |
| Web UI | `http://localhost:55173` |
| REST API | `http://localhost:54001/api/v1` |
| Core gRPC | `localhost:55051` |

Use the endpoints reported by your runtime if configured differently. Local
state defaults to `~/.mn` (`MN_HOME`). See
[Installation](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/installation.md)
for platform setup, release selection, upgrades, and editable workspace mode.

### 2. Validate and launch a blueprint

Choose a package from [Examples](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/examples.md)
or a blueprint author. Read its README, inputs, dependencies, and execution
policy first. A blueprint can execute code and call external services;
validation checks its contract, not whether it is safe to trust.

Run these commands from the directory containing your reviewed blueprint,
replacing `./my-blueprint` with its actual path:

```bash
mn blueprint validate ./my-blueprint
mn blueprint doctor ./my-blueprint
mn blueprint run ./my-blueprint --detached
```

Resolve the reported model, service, input, and hardware prerequisites before
launch. Local launch and doctor paths must begin with `./`, `../`, or `/`;
other values select catalog IDs. Launch can prepare resources and perform the
blueprint's external actions. `--detached` leaves execution running without the
live workflow UI.

### 3. Inspect the run and its results

Keep both IDs returned by launch. Replace `<job-id>` and `<run-id>` below with
those public IDs:

```bash
mn job show <job-id>
mn run show <run-id>
mn run watch <run-id>
mn run logs <run-id> --channel logs
mn run logs <run-id> --channel events
mn run result <run-id>
```

Ctrl+C detaches from the watcher. `run result` downloads outputs to
`$MN_HOME/outputs/<run-id>` by default. Check the terminal state, warnings,
artifacts, and required human review before using the result: completion is an
execution outcome, not a guarantee of correct conclusions.

If an unfinished run should stop, use `mn run cancel <run-id>`. Cancellation
cannot undo external actions already performed. When no other runs need the
local services, stop them with `mn runtime stop`.

Continue with the [full quickstart](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/quickstart.md)
and [CLI reference](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/cli.md).

## Execution and reliability boundaries

| Runner | Execution boundary |
| --- | --- |
| **HostLocal** | Runs trusted worker code directly in the host execution environment. |
| **DockerWorker** | Runs prepared commands in Docker containers; image, mounts, environment, and network access remain part of the contract. |

DockerWorker starts a stopped prepared container in place when a run uses it
after runtime shutdown. It leaves running containers untouched and fails before
dispatch when the prepared container is missing or paused; image preparation
and replacement remain owned by the SDK.
| **OpenShell** | Runs workers in a sandbox governed by explicit policy, uploads, and network access. |

Redis is the durable coordination store. Recovery can replay eligible work;
external effects need idempotency or independent deduplication. Arbitrary
process-local memory is not checkpointed, and exactly-once external effects are
not guaranteed.

Federated nodes share a trust domain. Local deployment does not by itself
ensure privacy: a blueprint can call configured remote providers and services.
See [Security](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/security.md)
and [Reliability](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/reliability.md)
for deployment and replay boundaries.

## Explore the ecosystem

| Component | Responsibility |
| --- | --- |
| **MirrorNeuron Core** — this repository | Workflow execution, supervision, scheduling, persistence, runners, and gRPC services. |
| [mn-cli](https://github.com/MirrorNeuronLab/mn-cli) | Install-facing runtime controls and blueprint, job, run, model, and node commands. |
| [mn-python-sdk](https://github.com/MirrorNeuronLab/mn-python-sdk) | Python integration, blueprint validation/compilation, bundle preparation, and runtime clients. |
| [mn-api](https://github.com/MirrorNeuronLab/mn-api) | REST gateway and streaming surfaces. |
| [mn-web-ui](https://github.com/MirrorNeuronLab/mn-web-ui) | Browser-based runtime and workflow inspection. |
| [mn-deploy](https://github.com/MirrorNeuronLab/mn-deploy) | Installation, Compose services, and release tooling. |
| [mn-agents](https://github.com/MirrorNeuronLab/mn-agents) / [mn-skills](https://github.com/MirrorNeuronLab/mn-skills) | Reusable agents and Python skill packages. |
| [Membrane](https://github.com/MirrorNeuronLab/Membrane) | Authoritative Markdown runtime memory and CPU DuckDB context retrieval through the SDK. |
| [mn-system-tests](https://github.com/MirrorNeuronLab/mn-system-tests) | Cross-component integration and system validation. |

Native Docker Compose service attempts report typed startup observations through
the existing worker-activity bridge. Serving requires a successful native project
health check and never completes a workflow step. The SDK binds manual-stop
projects to startup/service/shutdown phases during definition preparation; deploy
the matching SDK and Core together and prepare idle definitions again. Pause,
cancel and failure invalidate readiness, while exact project cleanup retains its
existing ownership contract.

Membrane keeps complete runtime text and durable receipts as Markdown, with
one disposable DuckDB index per job. It does not schedule tools or change the workflow DAG.
The development Compose template also publishes authenticated Membrane gRPC
on `127.0.0.1:${MN_CONTEXT_HOST_PORT:-50052}` for host-native SDK responders;
Docker clients retain the internal service address.
Read [Context memory and compression](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/context-memory.md)
for that contract.

## Develop Core

Core contributors need Elixir/Erlang compatible with [mix.exs](mix.exs)
(Elixir `~> 1.16`) and Redis for tests that exercise durable state. From a
project directory:

```bash
git clone https://github.com/MirrorNeuronLab/MirrorNeuron.git
cd MirrorNeuron
mix deps.get
mix format --check-formatted
mix test
mix compile --warnings-as-errors
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Integration tests may require Docker, OpenShell, Redis, or multiple machines.
Use the [development guide](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/development.md)
and [testing guide](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/testing.md)
for the relevant setup. To test changes across an editable workspace, follow
[local-mode installation](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/installation.md#install-an-editable-workspace-runtime).

```text
config/                     Runtime configuration
lib/mirror_neuron/          Runtime, persistence, federation, and runners
lib/mirror_neuron_grpc/     gRPC handlers and generated bindings
proto/                      Public protobuf service contracts
tests/                      Unit, E2E, and API tests
scripts/                    Development and release helpers
```

Read [AGENTS.md](AGENTS.md) and [SPEC.md](SPEC.md) before changing Core.
Keep domain behavior in blueprints, agents, and skills, and update the canonical
documentation when a public contract changes. See
[Contributing](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/contributing.md)
for the contributor workflow and [RELEASE.md](RELEASE.md) for Core distribution
and release procedures.

## Documentation

The detailed [mn-docs index](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/index.md)
is the source for cross-component guides and references.

| I want to… | Read |
| --- | --- |
| Write a workflow | [Blueprint standard](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/blueprint-standard.md) · [DAG flow patterns](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/dag-flow-patterns.md) |
| Integrate Python or HTTP | [Python SDK](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/SDK.md) · [REST API](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/api.md) |
| Operate recurring or service work | [Schedules and events](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/schedules-and-events.md) · [Deployments](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/deployments.md) |
| Add machines or model capacity | [Federation guide](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/cluster.md) · [Resources and devices](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/resources-and-devices.md) |
| Diagnose a failure | [Troubleshooting](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/troubleshooting.md) · [Environment variables](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/env_variables.md) |

## Security and license

Please use the repository's [security reporting page](https://github.com/MirrorNeuronLab/MirrorNeuron/security)
for vulnerabilities; do not disclose them in public issues.

MirrorNeuron Core is released under the [MIT License](LICENSE).

## Workflow invocation identity

Before a workflow handler executes, Core admits its source delivery through the
owning ledger and returns the authoritative attempt context. Deliveries waiting
for dependencies are retried without running the handler.

Workflow messages keep attempt context between workers in the same logical step.
Docker, OpenShell artifact handoff and HostLocal runners provide a stable
`MN_WORKFLOW_IDEMPOTENCY_KEY` per worker delivery; parallel specialists have
distinct keys. The original ledger key is available as
`MN_WORKFLOW_STEP_IDEMPOTENCY_KEY`. New logical steps receive their own attempt
through normal ledger admission.
Generated step sources collect multiple upstream deliveries under one attempt.
Child-workflow workers keep the child instance's attempt across source, worker,
join and sink boundaries; the template identity does not replace the instance.

HostLocal auxiliary services receive `MN_WORKFLOW_RUN_ID` from the owning
runtime even when their initial message has no workflow headers. Runtime
workflow fields override definition-time environment values, matching the
Docker and OpenShell runner contract. This physical identity can differ from
the `MN_RUN_ID` execution identity and identifies the shared run-output folder.

## HostLocal blueprint diagnostics

HostLocal supplies invocation-owned `MN_BUNDLE_ROOT` and
`MN_BLUEPRINT_MANIFEST_PATH` bindings so installed SDK handlers can load the
staged blueprint descriptor. A source manifest lookup must not depend on the
handler's `site-packages` directory. Deploy the updated Core on execution nodes;
a desktop-only update cannot repair this runner contract.

Command failures preserve their `mn.error.v1` code, exit status, runner, attempt
count and sanitized diagnostic tail through workflow failure and run completion.
The summary uses the last diagnostic line; long traceback prefixes cannot hide
the final exception. Existing shortened historical errors remain shortened.

## Response tool descriptions

Bounded response-agent tools accept an optional non-empty `description` of at
most 1,200 Unicode code points after trimming. Core preserves this planner
guidance without changing effects, argument validation, or execution authority.
Deploy this validator with the matching SDK common and job-response packages
before loading description-bearing blueprint declarations.
Core also accepts the SDK-derived manual (at most 64 KiB), standard Job activity
watch, typed scalar arguments, and schema-checked fixed polling arguments.
These fields retain the existing MCP tool and correlation boundaries.

Managed desktop Core requires its configured node identity at startup. The CLI
persists that identity independently of the network address and reports an
unnamed or mismatched Core as unready. After Wi-Fi changes, `mn runtime reconnect`
refreshes endpoint advertisements without restarting healthy Core processes.
Direct distributed-Erlang deployments retain their existing naming policy.

### OpenShell artifact handoff v1

Native SDK event blocks use `mn.block_events/v1`. Core advertises the supported
protocol to runners, validates the declared port/observation contract and applies
state only against the exact previous reference (or the same next reference on
replay). Stale transitions cannot overwrite later state. Emission idempotency keys
remain stable across retries. The SDK's process hook supplies logical-port values;
Core keeps routing, delivery and logical completion. OpenShell event transactions
are scoped to the physical message, and admit the previous state's verified
handoff graph before sandbox execution. This is source work requiring matching
SDK/blocks dev27 for the base event contract. CCTV v5.1 now uses native ingress
with the dev32 additions below; its three downstream workers remain pending.

Matching dev32 source adds event file publication. The SDK verifies
`outputs.published_files` without copying public names. Core accepts the event's
state transition first, then verifies every receipt/file and materializes outputs
under the physical run and configured submission output directory. Stale events
cannot overwrite later reports. Same-next replay repairs delivery after sandbox
cleanup without another domain invocation. Required copy errors retry; optional
copy failures produce `block_publication_warning` events. Integrity, path and
policy failures reject. Core advertises the publication protocol to runners;
the new SDK rejects missing support before hooks execute. The offline tests use
synthetic transports and do not qualify live OpenShell or CCTV hardware.

Set `artifact_handoff: {"version": "mn.artifact_handoff/v1"}` on an
OpenShell executor to use owner-node immutable artifact commits. The SDK's
`mn_sdk.artifact_handoff` helpers declare outputs and resolve verified inputs.
OpenShell is optional per worker. Stock SDK block and auxiliary workers use this same handoff
and require it when OpenShell is selected; HostLocal and Docker defaults remain.
Manifest handoff validation runs only for nodes selecting an OpenShell runner.
Core stages the complete referenced common JSON/byte input graph from the actual
owner run and supplies private sandbox run directories. Core also binds
`MN_BUNDLE_ROOT` and `MN_BLUEPRINT_MANIFEST_PATH` to the private invocation;
the matching SDK stages the compiled descriptor with the selected domain files.
The SDK packages output
graphs in `mn.block_handoff/v1`; Core verifies their declarations and commits
their bytes before downstream delivery. No blueprint transport wrapper or owner
store mount is needed. Use the matching SDK source/release with this Core change.
Main SDK dev31 block publication uses separate private logical output storage
(`local/job-outputs`) and declared handoff storage (`MN_ARTIFACT_OUTPUT_DIR`).
With `artifact_handoff.export_outputs: true`, Core delivers the SDK's verified
publication exports to the owner output folder and can repair delivery from a
committed receipt after sandbox cleanup, without another domain invocation.
SDK optional-file declarations retain required-report delivery when an optional
copy is unavailable. Core reports `export_warnings`; corrupt bytes and unsafe
paths remain errors, and required copy errors remain failures.
This mode rejects `sync_shared_storage: true`; that flag explicitly selects the
legacy whole-tree contract for unmigrated blueprints. Deploy the matching SDK
in worker images when upgrading Core.

Core records dispatch before execution, captures diagnostics separately, seals
and verifies declared files, and atomically publishes a receipt with their
bytes before releasing step results. Transfer retries never dispatch the worker.
A missing trustworthy execution record blocks replay; an operator must explicitly
start a new run to retry an unknown outcome. No exactly-once model-call guarantee
is claimed. Job sandbox caches are disposable and verified on every hit.

Receipts and transaction journals live under
`outputs/runs/<actual-runtime-run-id>/.handoff/` on the owning node. Startup
maintenance reconciles published receipts and independently retries cleanup.
Workflow replay can recover a committed executor result without the sandbox.
Owner storage loss is outside this durability guarantee. Replica consumers must
verify the receipt and every referenced file; filesystem replication alone is
not a completion signal.

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

## Retry failed runs

`PlanRunRetry` verifies recovery eligibility; `RetryRun` submits the verified
attempt/checkpoint selection with an idempotency key. These commands recover a
failed run under its existing run and stable job IDs, with a new attempt and
fenced lease epoch. `ResumeRun` continues paused work; it does not retry failures.
The CLI and OtterDesk use these same Core commands.

Logical checkpoints retain completed outputs, unfinished inputs, child-workflow
state and dynamic graph revisions. Recovery restores the ledger rather than
seeding the entire workflow or restoring process memory. Missing inputs, changed
bundles, corrupt artifacts, reset job data, active cleanup and uncertain external
effects block dispatch with a reason. Executor/module replay requires a declared
idempotency contract or a verified artifact handoff receipt; uncertain dispatches
remain blocked. Logical effect keys survive retry while delivery IDs change.
Dependency skips caused by a failed predecessor reopen on retry. Their reasons
are read from verified checkpoint output artifacts as well as inline outputs;
intentional branch skips and mapped-work placeholders remain preserved.
Unstarted downstream steps may obtain their first input when an unfinished
predecessor completes. Retry planning uses the saved graph edges to distinguish
them from entrypoints and already-dispatched steps, which require retained input.

Only explicitly supplied fields declared in manifest metadata
`run_retry.configuration_fields` may change. Fields declare `type: integer`
with `minimum`/`maximum`, or `type: string` with `allowed_values`. Original inputs,
workflow topology and result-defining configuration remain immutable. SDK contexts
receive `MN_RUN_RETRY_JSON` with effective overrides and preserved active usage.
An allowance of 60 minutes after 20 minutes of execution leaves 40 minutes;
queued, paused and failed intervals do not add to the durable run clock.
Executor invocations refresh their retry context from the fenced Core record
after queue admission, so preparation and paused intervals are not charged by a
stale startup context. A missing running lease blocks external invocation.

Failed control records, checkpoints and referenced bundles/artifacts are retained
until explicit run/job deletion or job-data reset. Logs and delivery history keep
their bounded retention. Resource status reports `retry_checkpoint_storage`.
Historical files alone do not establish eligibility: planning must verify the
remaining Core record and supported checkpoint. Run retry is manual only.
Artifact capture and retry verification have a bounded 60-second helper deadline.
Repeated immutable descriptors are checked once within each verification; every
new verification still checks the retained bytes and rejects changed hashes.

Oversized prompts use Membrane CPU preparation first, then optional original-ID
selection on the existing LiteLLM `default` route. No dedicated compressor model
is prepared. Managed SDK turns also retain source-backed working checkpoints.

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


Run placement failures expose bounded measured resource blockers to the SDK.
With updated Core and SDK services, callers receive the existing problem codes
(for example `MN_GPU_MEMORY_UNAVAILABLE` / `2001`), a friendly PC name, free
memory versus required memory, and safe remediation. Admission requirements are
unchanged. See [SPEC.md](SPEC.md) for the versioned admission detail contract.

## Model residency across checkpoint retries

Checkpoint retries retain their run ID and use `MN_ATTEMPT_ID` for managed-model
ownership. Preparation, gateway requests, native records, and terminal cleanup
carry the same attempt identity. Finishing an attempt closes only its model
references; a later attempt can prepare the model without reopening the old
attempt. Delayed cleanup and garbage collection cannot release a later
attempt's model. Unversioned callers keep their existing run-scoped fences.
Upgrade Core, the native SDK, gateway callbacks, and prepared worker SDKs
together; saved worker images keep the SDK version with which they were built.

The LiteLLM gateway defaults to five concurrent completion calls and five
concurrent embedding calls per model group. Its private model-owner routes
also use `max_parallel_requests: 5`. Set `MN_LITELLM_MAX_CONCURRENT_REQUESTS`
and `MN_LITELLM_MAX_CONCURRENT_EMBEDDINGS` to apply lower per-group limits;
queue size and timeout settings remain independent.

## Standard runtime activity

Runtime events use the shared [`mn.runtime.event.v1` contract](../mn-python-sdk/docs/runtime-activity.md),
including level, blueprint owner, UTC timestamp and actor attribution.
The SDK selects meaningful activity for the CLI, API, desktop and web monitors;
raw events remain available for diagnostics.


### Automatic waiting for a busy PC

Resource node reports include `cpu_load_average_1m` from the native hardware
snapshot. Missing samples are null. This is one-minute CPU load, distinct from
CPU utilization and reserved capacity.

A PC owns one active run, with all its GPUs, CPU and memory shared by that run's
workers/models. A second start is accepted into its durable FIFO and starts
automatically after terminal cleanup. `paused` retains the reservation. Read
`admission` on the Run and inspect its `queue_<run_id>` schedule; cancelling that
schedule cannot stop a run that has already begun. Core and native SDK peers must
advertise `exclusive_run_v1`. See the exclusive run admission section of SPEC.md.
Federation refreshes carry each PC's current holder and queue into node/resource
reports, so new co-workers prefer an idle compatible PC. Existing prepared Jobs
keep their owner and its local resources; refreshing capacity does not move them.
Keyed starts retain Redis-backed request identities and receipts across Core
restart, including reconciliation after an interrupted receipt write. Queue
schedule revisions advance on mutation so stale cancel/reschedule controls fail.

After admission, SDK-staged inputs may still be replicating to the owner PC.
The job coordinator keeps the run `pending`, publishes `submission_storage_waiting`,
and starts work automatically after its inventory and every file pass verification.
Both immediate and FIFO-queued starts use this same gate. Incomplete replication
does not request human review or fail admission; invalid metadata and the existing
`MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS` deadline still fail before any input is
delivered. Cancelling while waiting prevents a later start.
`tests/e2e/submission_readiness_test.exs` covers delayed inventory/files, partial
and corrupt copies, queue dispatch, cancellation, timeout and invalid metadata
through stable Job launches with an isolated Redis namespace and temporary files.

## Workflow action allowances

Compiled `policies.workflow_budgets` declare named action limits for an actual
workflow run. The SDK's `RunActionBudget` uses authenticated resource commands;
the job coordinator owns atomic admission and persists reservations before
granting work. Core resolves the owner by the stable Job ID and actual workflow
run ID supplied by workers, independently of the execution's coordinator ID.
Isolated workers share that owner rather than copied local
counters. Duplicate requests/completions are idempotent; changed requests,
foreign scopes and stale runs reject. Unknown starts stay charged. The allowance
survives checkpoint recovery and resets only for an explicitly new workflow run.
Provider effects still need their native journals. Deploy the matching dev30
SDK/blocks and Core support together; offline tests do not qualify a live rollout.

Public workflow definitions retain the SDK's service startup/shutdown metadata
so clients can finish startup progress when a live service begins serving.
The actual service step remains running until its owning lifecycle ends.

Resource-aware admission, queueing, reclamation and idle Job transfers are described in [Run resource allocation](docs/resource-allocation.md).

Regenerate the Job wire bindings in Core and the sibling SDK with
`bash scripts/generate_job_proto.sh ../mn-python-sdk` (requires protoc and uv).
