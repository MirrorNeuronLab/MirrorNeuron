<h1 align="center">MirrorNeuron 🧠</h1>

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

## Why MirrorNeuron?

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

Batch jobs can retain multiple runs. Service jobs retain at most one attached
run, and pause/resume preserves that identity. Retries belong to the same run
and have their own attempt identity.

Blueprint authors declare the logical workflow separately from worker execution.
Core owns scheduling and completion boundaries; agents and skills own task
behavior. Dynamic workflows can instantiate admitted templates within declared
bounds. They cannot arbitrarily rewrite running work.

Read [Core concepts](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/core-concepts.md),
[Blueprint format](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/blueprint-standard.md),
and [Runtime architecture](https://github.com/MirrorNeuronLab/mn-docs/blob/HEAD/runtime-architecture.md)
for the full contracts.

### One owner per job, independent machines

Each federated Core has its **own writable Redis**. A job and all of its workers
stay on one owner Core. Peers exchange authenticated gRPC requests and cached
job/run summaries; federation does not require shared Redis or a Distributed
Erlang cluster.

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
| [Membrane](https://github.com/MirrorNeuronLab/Membrane) | Working memory, context selection, and compression through the SDK and model gateway. |
| [mn-system-tests](https://github.com/MirrorNeuronLab/mn-system-tests) | Cross-component integration and system validation. |

Membrane keeps model context bounded while durable artifacts preserve the
underlying evidence. It does not schedule tools or change the workflow DAG.
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

## Response tool descriptions

Bounded response-agent tools accept an optional non-empty `description` of at
most 1,200 Unicode code points after trimming. Core preserves this planner
guidance without changing effects, argument validation, or execution authority.
Deploy this validator with the matching SDK common and job-response packages
before loading description-bearing blueprint declarations.
Managed desktop Core requires its configured node identity at startup. The CLI
persists that identity independently of the network address and reports an
unnamed or mismatched Core as unready. After Wi-Fi changes, `mn runtime reconnect`
refreshes endpoint advertisements without restarting healthy Core processes.
Direct distributed-Erlang deployments retain their existing naming policy.
