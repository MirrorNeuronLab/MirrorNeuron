# MirrorNeuron

Last edited: 2026-04-05

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
  - `mirror_neuron`
- example bundles for:
  - local workflows
  - shell and Python execution
  - large fan-out scale tests
  - streaming telemetry and anomaly detection
  - shared PettingZoo MPE crowd visualization
  - LLM codegen/review loops
  - large-scale ecosystem simulation
  - See [MirrorNeuron Blueprints](https://github.com/MirrorNeuronLab/mirrorneuron-blueprints)

## Blueprints and Examples

All example workflows, including the `research_flow` and `ecosystem_simulation`, have been moved to a separate repository: [MirrorNeuron Blueprints](https://github.com/MirrorNeuronLab/mirrorneuron-blueprints).


## Installation

You can install MirrorNeuron using the one-line install script on macOS, Linux, or WSL. This script clones the repository, builds the executable, and sets up `mn` and `mirror_neuron` aliases in your `~/.local/bin` directory.

```bash
curl -fsSL https://raw.githubusercontent.com/homerquan/MirrorNeuron/main/install.sh | bash
```

*Note: You must have Erlang and Elixir installed on your system before running the script. If you do not have them installed, the script will provide instructions for your operating system.*

## Quickstart

```bash
cd MirrorNeuron
mix deps.get
mix test
mix escript.build

./mirror_neuron validate /path/to/mirrorneuron-blueprints/research_flow
./mirror_neuron run /path/to/mirrorneuron-blueprints/research_flow
./mirror_neuron monitor
```

For full setup instructions:

- [Installation](docs/installation.md)
- [Quickstart](docs/quickstart.md)

## Documentation

Main documentation index:

- [docs/index.md](docs/index.md)

Recommended reading order:

1. [Installation](docs/installation.md)
2. [Quickstart](docs/quickstart.md)
3. [Examples Guide](docs/examples.md)
4. [CLI Guide](docs/cli.md)
5. [Monitor Guide](docs/monitor.md)
6. [Runtime Architecture](docs/runtime-architecture.md)
7. [Reliability Guide](docs/reliability.md)
8. [API Reference](docs/api.md)
9. [Troubleshooting](docs/troubleshooting.md)
10. [Development Guide](docs/development.md)
11. [Simulation Example](docs/simulation_example.md)
12. [Shared MPE Crowd Example](docs/mpe_simple_push_example.md)

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
  - `agent_type` selects the runtime primitive
  - `type` selects the behavioral template and defaults to `generic`
- `payloads/` contains code and files needed by worker execution


- [MirrorNeuron Blueprints](https://github.com/MirrorNeuronLab/mirrorneuron-blueprints) (External repository with examples)

## Main commands

```bash
./mirror_neuron validate <job-folder>
./mirror_neuron run <job-folder>
./mirror_neuron node list
./mirror_neuron job inspect <job_id>
./mirror_neuron job list [--live]
./mirror_neuron events <job_id>
./mirror_neuron monitor
```

For full command reference:

- [CLI Guide](docs/cli.md)

## Cluster and monitoring

MirrorNeuron supports two-box dev-mode clustering and clustered example harnesses.

Key docs:

- [Cluster Guide](docs/cluster.md)
- [Monitor Guide](docs/monitor.md)
- [Reliability Guide](docs/reliability.md)

## Public API surface

The current public inspection and control APIs are documented here:

- [API Reference](docs/api.md)

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

For the current reliability model and known limits:

- [Reliability Guide](docs/reliability.md)

## Contributing

If you are working on the runtime itself, start here:

- [Development Guide](docs/development.md)

## License

MirrorNeuron is available under the [MIT License](LICENSE).
