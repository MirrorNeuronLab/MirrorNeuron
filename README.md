# MirrorNeuron

MirrorNeuron is an Elixir/BEAM runtime for orchestrating multi-agent workflows with bounded sandbox execution.

It is built around a simple runtime split:

- BEAM handles orchestration, supervision, message routing, clustering, and persistence
- OpenShell handles isolated execution for `executor` nodes

MirrorNeuron is not trying to be a general-purpose batch scheduler. It is designed for event-driven, message-oriented workflows where logical agents collaborate and only the heavy execution path leaves BEAM.

## Highlights

- small built-in primitive set: `router`, `executor`, `aggregator`, `sensor`
- Redis-backed job state, agent snapshots, and event history
- BEAM cluster support with `libcluster` and `Horde`
- bounded execution capacity through executor leases and pools
- shared OpenShell sandbox reuse per job per runtime node
- terminal-first tooling with:
  - [mirror_neuron](/Volumes/1TB/Personal_projects/MirrorNeuron/mirror_neuron)
  - [mirror_neuron_monitor](/Volumes/1TB/Personal_projects/MirrorNeuron/mirror_neuron_monitor)
- example bundles for:
  - local workflows
  - shell and Python execution
  - large fan-out scale tests
  - LLM codegen/review loops

## Quickstart

```bash
cd /Volumes/1TB/Personal_projects/MirrorNeuron
mix deps.get
mix test
mix escript.build

./mirror_neuron validate examples/research_flow
./mirror_neuron run examples/research_flow
./mirror_neuron_monitor
```

For full setup instructions:

- [Installation](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/installation.md)
- [Quickstart](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/quickstart.md)

## Documentation

Main documentation index:

- [docs/index.md](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/index.md)

Recommended reading order:

1. [Installation](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/installation.md)
2. [Quickstart](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/quickstart.md)
3. [Examples Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/examples.md)
4. [CLI Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/cli.md)
5. [Monitor Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/monitor.md)
6. [Runtime Architecture](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/runtime-architecture.md)
7. [API Reference](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/api.md)
8. [Troubleshooting](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/troubleshooting.md)
9. [Development Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/development.md)

## Core ideas

### Runtime primitives

MirrorNeuron keeps the built-in runtime small:

- `router`
- `executor`
- `aggregator`
- `sensor`

This keeps the core generic and reusable. Domain-specific agent logic belongs in job bundles or user extensions, not in the runtime kernel.

### Logical workers vs execution leases

MirrorNeuron distinguishes:

- logical workers: cheap BEAM processes that hold workflow state
- execution leases: scarce sandbox capacity used by `executor` nodes

This is the key reason the runtime scales better than “launch one sandbox for every worker immediately.”

### Message-driven workflows

Workflows are defined as graph bundles:

```text
job-folder/
  manifest.json
  payloads/
```

- `manifest.json` defines nodes, edges, entrypoints, and policies
- `payloads/` contains code and files needed by worker execution

## Included examples

- [examples/research_flow](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/research_flow)
- [examples/openshell_worker_demo](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/openshell_worker_demo)
- [examples/prime_sweep_scale](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/prime_sweep_scale)
- [examples/llm_codegen_review](/Volumes/1TB/Personal_projects/MirrorNeuron/examples/llm_codegen_review)

For details:

- [Examples Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/examples.md)

## Main commands

```bash
./mirror_neuron validate <job-folder>
./mirror_neuron run <job-folder>
./mirror_neuron inspect nodes
./mirror_neuron inspect job <job_id>
./mirror_neuron events <job_id>
./mirror_neuron_monitor
```

For full command reference:

- [CLI Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/cli.md)

## Cluster and monitoring

MirrorNeuron supports two-box dev-mode clustering and clustered example harnesses.

Key docs:

- [Cluster Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/cluster.md)
- [Monitor Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/monitor.md)

## Public API surface

The current public inspection and control APIs are documented here:

- [API Reference](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/api.md)

These APIs are intended to support:

- terminal monitoring
- future dashboards
- operational scripts
- external integrations

## Current scope

MirrorNeuron already supports:

- local execution
- clustered execution
- Redis-backed persistence
- OpenShell-backed executor isolation
- terminal monitoring

It is still evolving in areas like:

- stronger HA and failover
- richer deferred/sensor semantics
- broader artifact-store integration
- more advanced scheduling and recovery policies

## Contributing

If you are working on the runtime itself, start here:

- [Development Guide](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/development.md)
