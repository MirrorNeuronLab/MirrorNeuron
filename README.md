# MirrorNeuron
## Overview

MirrorNeuron is an Elixir/BEAM runtime for orchestrating distributed workflows with multiple autonomous agents. It lets you define complex multi-step jobs as agent graphs, then execute them reliably with built-in support for persistence, clustering, and sandboxed execution.

**Why use it?**

- **Scale workflows, not just tasks**: Define logical agent networks of any size and let the runtime handle execution
- **Explicit control flow**: Message routing, capacity limits, and execution queues are first-class concepts
- **Built for reliability**: Redis-backed state, pause/resume, and replay-friendly event history
- **Production-ready**: BEAM clustering, sandboxed code execution via OpenShell, and CLI tooling included
- **Start simple**: Small primitive set (`router`, `executor`, `aggregator`, `sensor`) keeps the mental model lean

**What it solves:**

Instead of managing job orchestration through external workflow engines or ad-hoc scripting, MirrorNeuron keeps the control plane lightweight while scaling your agent logic independently. Separate concerns: logical workflows stay in BEAM, heavy execution happens in isolated sandboxes.

---
**Note:** This is partially inspired by the author's real-time decision engine using multi-actor systems for large-scale monitoring and simulation (e.g., traffic optimization problems). The [original work from 2015](https://github.com/homerquan/mirrorneuron_legacy_scala_actor) demonstrated how distributed agents could coordinate complex workflows at scale; this implementation brings those patterns to AI multi agent problem.

## What is included

- Job bundle loader and manifest validator
- Supervised per-job runtime tree
- Long-lived `GenServer` agent workers
- Explicit internal message envelopes and event bus
- Redis persistence for job state, agent snapshots, and event history
- BEAM cluster support using `libcluster` + `Horde`
- Optional OpenShell sandbox execution for `executor` nodes only
- CLI commands for `validate`, `run`, `inspect`, `events`, `pause`, `resume`, `cancel`, and `send`
- Small runtime primitive set:
  - `router`, `executor`, `aggregator`, `sensor`
- Agent SDK surface for custom extensions:
  - [agent.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/agent.ex)
  - [agent_template.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/agent_template.ex)
  - [agent_templates/accumulator.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/agent_templates/accumulator.ex)

## Project layout

- [mix.exs](/Volumes/1TB/Personal_projects/MirrorNeuron/mix.exs)
- [lib/mirror_neuron.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron.ex)
- [lib/mirror_neuron/agent.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/agent.ex)
- [lib/mirror_neuron/builtins/router.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/builtins/router.ex)
- [lib/mirror_neuron/builtins/executor.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/builtins/executor.ex)
- [lib/mirror_neuron/builtins/aggregator.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/builtins/aggregator.ex)
- [lib/mirror_neuron/builtins/sensor.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/builtins/sensor.ex)
- [lib/mirror_neuron/manifest.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/manifest.ex)
- [lib/mirror_neuron/runtime/job_coordinator.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/runtime/job_coordinator.ex)
- [lib/mirror_neuron/runtime/agent_worker.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/runtime/agent_worker.ex)
- [lib/mirror_neuron/persistence/redis_store.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/persistence/redis_store.ex)

## Runtime model

MirrorNeuron is a runtime platform, not a library of business agents. The manifest defines collaboration and the runtime provides the execution substrate:

- every node in the manifest becomes a supervised agent worker
- edges describe allowed message flow
- the job coordinator owns lifecycle and persistence
- the event bus captures observability and replayable history

The built-in primitives are intentionally small:

- `router`: fan-out or pass-through message routing
- `executor`: sandboxed code execution through OpenShell
- `aggregator`: barrier/join/reduce for merging worker outputs
- `sensor`: lightweight event gate for waiting on messages or readiness signals

Legacy generic names `relay`, `sandbox_worker`, and `collector` are still accepted as compatibility aliases, but the runtime now documents only the primitive names above.

Two design rules now shape the runtime:

- logical workers are cheap BEAM processes that own workflow state
- physical execution leases are scarce OpenShell slots that must be granted explicitly

That separation matters because it lets the runtime scale the agent graph without trying to start every sandbox at once.

## Why these changes were made

Earlier versions were structurally correct for small demos, but they let every executor node launch OpenShell immediately. In practice that creates pressure in exactly the wrong place:

- OpenShell gateway resets under large fan-out
- OS subprocess and file descriptor churn
- expensive execution capacity is treated like cheap BEAM process capacity

The runtime now adds a per-node executor lease manager so `executor` nodes queue for capacity before launching sandboxes. This keeps the control plane lightweight while still allowing large logical graphs and high message volume.

This project does borrow a few ideas from Airflow, but only at the control-plane level:

- small built-in primitive set
- explicit heavy-work capacity control with pools and slots
- clear separation between workflow definition and runtime execution
- small control messages with artifact references instead of giant inline payloads

It does not try to become a general data-batch scheduler.

## Message model

Messages are now normalized into an explicit runtime envelope:

- `envelope`: runtime-owned routing and trace metadata
- `headers`: extensible metadata for schemas, routing hints, and policies
- `body`: application-owned payload
- `artifacts`: references to large externalized outputs
- `stream`: optional streaming metadata for chunked or progressive delivery

This matters for two reasons:

- the runtime can stay generic and route without understanding application payloads
- worker code inside a sandbox can still consume richer application-specific fields

Supported payload forms include JSON, NDJSON, and compressed Erlang binary for internal use. Streaming payloads are modeled with explicit `stream` metadata instead of hiding chunking inside ad hoc JSON fields.

## Executor capacity

Executor capacity is now bounded per runtime node.

Environment variables:

- `MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY`
  default executor slots for the `default` pool, default `4`
- `MIRROR_NEURON_EXECUTOR_POOL_CAPACITIES`
  optional comma-separated overrides like `default=4,gpu=1,io=8`

Executor node config can request a pool:

```json
{
  "agent_type": "executor",
  "config": {
    "pool": "default",
    "pool_slots": 1
  }
}
```

What this means operationally:

- 1000 logical workers is fine
- 1000 concurrent OpenShell sandboxes on one machine is usually not
- the runtime now queues executor work until a lease is available

`./mirror_neuron inspect nodes` now reports executor pool capacity and current usage per connected node.

## Job bundle format

Every input is now a folder:

```text
job-folder/
  manifest.json
  payloads/
    ...
```

- `manifest.json` defines the agent graph, edges, entrypoints, and policies
- `payloads/` stores any worker assets: code, scripts, packages, Docker context, or other files needed by executor nodes

## Example bundles

- [examples/research_flow](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/research_flow)
- [examples/openshell_worker_demo](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/openshell_worker_demo)
- [examples/prime_sweep_scale](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/prime_sweep_scale)

## CLI

```bash
mix deps.get
mix escript.build

./mirror_neuron validate examples/research_flow
./mirror_neuron run examples/research_flow
./mirror_neuron inspect nodes
```

MirrorNeuron stores jobs, agent snapshots, and event history in Redis under the `mirror_neuron:*` namespace by default.

CLI behavior:

- `./mirror_neuron run <job-folder>` shows a live progress line with status, elapsed time, event count, collected result count, and sandbox completion count
- the progress line also shows executor lease pressure with `running` and `waiting` counts
- `./mirror_neuron run <job-folder> --json` is intended for scripts and returns the final job payload as JSON

## Test On A Local PC

This is the exact setup flow used to test the examples on a local machine.

1. Install Elixir so `mix` is available.

```bash
brew install elixir
elixir --version
mix --version
```

2. Start Docker Desktop or another local Docker daemon.

3. Start Redis in Docker.

```bash
docker rm -f mirror-neuron-redis 2>/dev/null || true
docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7
docker exec mirror-neuron-redis redis-cli ping
```

You should see `PONG`.

4. Install OpenShell from NVIDIA's official installer.

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
~/.local/bin/openshell --version
```

If `openshell` is not already on your `PATH`, either export it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

or point MirrorNeuron at it directly:

```bash
export MIRROR_NEURON_OPENSHELL_BIN="$HOME/.local/bin/openshell"
```

5. Start the OpenShell gateway and confirm it is connected.

```bash
openshell gateway start
openshell status
```

6. Build MirrorNeuron.

```bash
cd /Volumes/1TB/Personal_projects/MirrorNeuron
mix deps.get
mix test
mix escript.build
```

7. Validate the job bundles.

```bash
./mirror_neuron validate examples/research_flow
./mirror_neuron validate examples/openshell_worker_demo
```

8. Run the examples.

```bash
./mirror_neuron run examples/research_flow --json
./mirror_neuron run examples/openshell_worker_demo --json
./mirror_neuron inspect nodes
```

Current local result:

- `research_flow` completes successfully
- `openshell_worker_demo` completes successfully

9. Optional cleanup.

```bash
docker rm -f mirror-neuron-redis
```

## Large-Scale Prime Benchmark

There is also a generated large-scale benchmark for testing runtime scalability with many worker agents.

The benchmark shape is:

- `dispatcher` router node as the root entrypoint
- `N` executor workers, each scanning one range chunk for primes
- one `aggregator` agent that merges all chunk results and completes when all worker chunks arrive

Files:

- generator: [examples/prime_sweep_scale/generate_bundle.py](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/prime_sweep_scale/generate_bundle.py)
- worker payload: [examples/prime_sweep_scale/payloads/prime_worker/scripts/check_prime_range.py](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/prime_sweep_scale/payloads/prime_worker/scripts/check_prime_range.py)
- runner: [examples/prime_sweep_scale/run_scale_test.sh](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/prime_sweep_scale/run_scale_test.sh)
- result summarizer: [examples/prime_sweep_scale/summarize_result.py](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/prime_sweep_scale/summarize_result.py)

Generate and run a 1,000-worker benchmark:

```bash
bash examples/prime_sweep_scale/run_scale_test.sh --workers 1000 --start 1000003
```

Arguments:

- `--workers` or `-w`: logical worker count
- `--start` or `-s`: starting integer for candidate generation
- `--end` or `-e`: optional inclusive upper boundary
- `--chunk-size` or `-c`: chunk size per worker, default `100`
- `--wave-size`: worker launch wave size, default `25`
- `--wave-delay-ms`: delay between launch waves in milliseconds, default `250`
- `--max-attempts`: max OpenShell attempts per worker, default `4`
- `--retry-backoff-ms`: base retry backoff in milliseconds, default `500`
- `--dry-run`: generate the bundle only

The generator writes a bundle under `examples/prime_sweep_scale/generated/`, runs it, stores the raw CLI output as `result.json`, and prints a compact summary with:

- total worker chunks
- total checked numbers
- prime count
- first and last prime hits
- covered range

The benchmark now uses a more realistic runtime model:

- the manifest may contain 1000 logical executor nodes
- each executor requests a bounded lease before starting OpenShell
- actual concurrent sandboxes are capped by `MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY` or pool overrides

For example, this is a good conservative local setup:

```bash
export MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY=4
bash examples/prime_sweep_scale/run_scale_test.sh --workers 1000 --start 1000003 --end 1100007
```

If you want to inspect the generated bundle without running it:

```bash
bash examples/prime_sweep_scale/run_scale_test.sh --workers 1000 --start 1000003 --end 1100007 --dry-run
```

That writes the bundle into `/tmp` and prints the folder path.

Important behavior note:

- `--workers` is authoritative
- if you also pass `--end`, the runner does not silently expand worker count
- instead it warns if the requested workers do not fully cover the upper boundary

So this command really runs two logical workers:

```bash
bash examples/prime_sweep_scale/run_scale_test.sh --workers 2 --start 1000003 --end 1100007
```

For a smaller local smoke check before trying 1,000 workers:

```bash
bash examples/prime_sweep_scale/run_scale_test.sh --workers 32 --start 1000003 --chunk-size 50
```

For larger runs, the generated manifest now staggers worker startup in waves and lets each `executor` retry transient OpenShell transport failures. This is important for avoiding gateway overload when hundreds of sandboxes are created at once.

The runner also cleans up stale benchmark sandboxes with the `prime-worker-` prefix before and after each run. If you want to skip that cleanup, set:

```bash
export MIRROR_NEURON_SKIP_BENCHMARK_SANDBOX_CLEANUP=1
```

Notes:

- this benchmark uses `executor`, so Redis, Docker, and OpenShell must already be working
- the first run is slower because OpenShell may need to pull the base sandbox image
- a 1,000-worker run is meant as a scalability test, not a quick demo

If a run appears to hang for a long time, especially after earlier large benchmarks, the most common cause is stale OpenShell sandboxes stuck in `Provisioning`.

Useful checks:

```bash
openshell status
openshell sandbox list
./mirror_neuron inspect nodes
```

If the gateway is unhealthy or old benchmark sandboxes are still hanging around, reset OpenShell before retrying:

```bash
openshell gateway destroy --name openshell
openshell gateway start
openshell status
openshell sandbox list
```

Then rerun a small smoke test first:

```bash
bash examples/prime_sweep_scale/run_scale_test.sh --workers 2 --start 1000003
```

Practical guidance:

- if `inspect nodes` shows executor capacity is available, but the run is still hanging, the bottleneck is usually OpenShell provisioning rather than BEAM scheduling
- stale `prime-worker-*` sandboxes from older runs can slow down or block fresh tests even when the current job only uses a few workers
- the scale runner already tries to clean up `prime-worker-*` sandboxes, but if OpenShell itself is wedged, a full gateway restart is the safer recovery path

## Worker sandboxes only

MirrorNeuron remains the BEAM orchestrator. OpenShell is only used for nodes whose `agent_type` is `executor`.

- job coordination stays in BEAM
- inter-agent routing stays in BEAM
- supervision, pause/resume, persistence, and cluster control stay in BEAM
- only the actual worker command for `executor` nodes is executed inside OpenShell

## OpenShell executor nodes

For `executor` nodes, the runtime shells out to the OpenShell CLI using the non-interactive command path:

```bash
openshell sandbox create --upload <local_dir>:<remote_dir> --no-keep -- <command>
```

Install OpenShell first:

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
```

If the binary is not on your default `PATH`, set:

```bash
export MIRROR_NEURON_OPENSHELL_BIN="/absolute/path/to/openshell"
```

Then start a gateway once on the host that will run sandboxes:

```bash
openshell gateway start
openshell status
```

Useful `executor` config fields:

- `from`: sandbox image or community sandbox name, usually `base`
- `upload_path`: file or directory under `payloads/` to stage into the sandbox
- `upload_as`: target directory name inside the staged upload root
- `workdir`: working directory inside the sandbox
- `command`: shell string or argv list to run inside the sandbox
- `output_message_type`: message type emitted to downstream agents
- `policy`: optional OpenShell policy YAML path
- `remote`: optional remote gateway bootstrap target
- `providers`: optional OpenShell provider names

For bundle-based runs, relative `upload_path` values are resolved against the job folder’s `payloads/` directory.

The runtime writes two files into every staged sandbox upload:

- `mirror_neuron_input.json`: the current message payload
- `mirror_neuron_context.json`: job and agent metadata

Inside the sandbox those are exposed through:

- `MIRROR_NEURON_INPUT_FILE`
- `MIRROR_NEURON_CONTEXT_FILE`
- `MIRROR_NEURON_WORKDIR`

## Running a clustered runtime

Each machine must:

- run Redis reachable by every node
- use the same Erlang cookie
- start the runtime with a node name
- point `MIRROR_NEURON_CLUSTER_NODES` at the full list of runtime nodes

Example for node 1:

```bash
export ERL_AFLAGS="-setcookie mirrorneuron"
export MIRROR_NEURON_REDIS_URL="redis://10.0.0.10:6379/0"
export MIRROR_NEURON_CLUSTER_NODES="mn1@10.0.0.11,mn2@10.0.0.12"

iex --name mn1@10.0.0.11 -S mix
```

Then inside `iex`:

```elixir
MirrorNeuron.CLI.main(["server"])
```

Example for node 2:

```bash
export ERL_AFLAGS="-setcookie mirrorneuron"
export MIRROR_NEURON_REDIS_URL="redis://10.0.0.10:6379/0"
export MIRROR_NEURON_CLUSTER_NODES="mn1@10.0.0.11,mn2@10.0.0.12"

iex --name mn2@10.0.0.12 -S mix
```

Then inside `iex`:

```elixir
MirrorNeuron.CLI.main(["server"])
```

Once the nodes see each other through EPMD, `Horde` can place jobs and agent workers across the cluster and agent-to-agent communication uses BEAM messaging between nodes.

To run one-shot CLI commands from any machine and have them join the cluster, set a temporary node name and cookie first:

```bash
export MIRROR_NEURON_NODE_NAME="cli@10.0.0.20"
export MIRROR_NEURON_COOKIE="mirrorneuron"
export MIRROR_NEURON_REDIS_URL="redis://10.0.0.10:6379/0"
export MIRROR_NEURON_CLUSTER_NODES="mn1@10.0.0.11,mn2@10.0.0.12"

./mirror_neuron inspect nodes
./mirror_neuron run examples/research_flow
```

## Demo: shell + Python worker bundle

The demo bundle is intentionally small and fast. It includes:

1. a shell payload folder with `scripts/collect_metrics.sh`
2. a Python payload folder with `scripts/build_report.py`
3. an aggregator sink that completes the job

Run it directly:

```bash
./mirror_neuron validate examples/openshell_worker_demo
./mirror_neuron run examples/openshell_worker_demo --json
```

Or use the helper script:

```bash
bash demo/openshell_pipeline/run_demo.sh
bash demo/openshell_pipeline/run_demo.sh --job-path /Volumes/1TB/Personal_projects/MirrorNeuron/examples/openshell_worker_demo --no-json
```

## Current scope

This is still an MVP runtime. It now supports BEAM clustering and Redis persistence, but it does not yet include a separate gateway API, advanced placement policies, or node-failure recovery orchestration beyond what BEAM/Horde provide.
