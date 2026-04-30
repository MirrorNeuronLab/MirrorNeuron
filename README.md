# 🧠 MirrorNeuron: On-Edge AI Infrastructure

### Durable runtime and control plane for adaptive AI workflows at the edge.

MirrorNeuron is an open-source runtime for AI systems that need to run close to data, users, devices, sensors, robots, private networks, and local compute.

It provides the missing execution layer for **long-running, stateful, observable, and adaptive AI workflows** — from a developer laptop to edge nodes, private clusters, and hybrid cloud environments.

<!-- start-badges -->
[![License](https://img.shields.io/badge/License-MIT-blue)](https://github.com/MirrorNeuronLab/MirrorNeuron/blob/main/LICENSE)
[![Security Policy](https://img.shields.io/badge/Security-Report%20a%20Vulnerability-red)](https://github.com/MirrorNeuronLab/MirrorNeuron/security/policy)
[![Project Status](https://img.shields.io/badge/status-alpha-orange)](https://github.com/MirrorNeuronLab/mn-docs)
[![On-Edge AI](https://img.shields.io/badge/On--Edge%20AI-Infrastructure-purple)](https://mirrorneuron.io)
[![Docs](https://img.shields.io/badge/Docs-mn--docs-blue)](https://github.com/MirrorNeuronLab/mn-docs)
[![Discord](https://img.shields.io/badge/Discord-Join-7289da)](https://discord.com/invite/XmSQqFEz)
<!-- end-badges -->

> [!IMPORTANT]
> MirrorNeuron is in **alpha / developer preview**. The core direction is stable, but APIs, blueprints, and ecosystem components may evolve quickly. We are releasing early to invite contributors, design partners, and real-world feedback.

---

## The Thesis

AI is moving from cloud-only chat interfaces into real-world operational systems.

```text
Models are becoming available.
Agents are becoming useful.
Reliable on-edge execution is still missing.
```

MirrorNeuron is building that missing layer: **durable, adaptive infrastructure for AI workflows that run where work actually happens**.

---

## Quick Install

```bash
curl -fsSL https://mirrorneuron.io/install.sh | bash
```

---

## Launch Something Useful

Run a real multi-agent blueprint with one command:

```bash
mn blueprint run science_drug_discovery_deamon
```

This is intended to demonstrate MirrorNeuron as a runtime for useful AI workflows, not just a toy prompt demo.

Expected flow:

- the blueprint is resolved
- the workflow graph is validated
- agents begin executing
- progress is visible through runtime events
- intermediate state and outputs are tracked
- the workflow can recover from interruptions or failures

---

## Why On-Edge AI Infrastructure?

AI systems are moving closer to where data is created and decisions are made:

- private enterprise environments
- robotics and physical AI platforms
- factories, labs, clinics, vehicles, and field operations
- developer machines and local clusters
- hybrid systems that combine local execution with cloud services

This shift creates a new infrastructure bottleneck.

Models can run locally. Tools can be called remotely. Agents can be composed. But real-world systems still need a runtime that can coordinate agents, preserve state, recover from failures, expose observability, enforce policies, and adapt to changing conditions.

MirrorNeuron is built for that bottleneck.

### Why now?

| Driver | Why it matters |
|---|---|
| **Privacy** | Sensitive data often needs to stay inside a device, site, lab, enterprise network, or regulated environment. |
| **Latency** | Robots, industrial systems, interactive agents, and real-time workflows cannot always wait for cloud round trips. |
| **Bandwidth** | Sending every sensor stream, video frame, tool call, and intermediate state to the cloud is expensive and brittle. |
| **Reliability** | Edge systems must continue operating when networks are slow, intermittent, or unavailable. |
| **Ownership** | Teams increasingly want control over where models, agents, tools, and workflow state actually run. |
| **Opportunity** | As inference moves closer to data, the bottleneck shifts from model access to orchestration, reliability, and control. |

### Industry context

- NVIDIA describes edge computing as useful for faster response times, lower bandwidth costs, and resilience from network failure: https://blogs.nvidia.com/blog/what-is-edge-ai/
- McKinsey notes that a significant portion of inferencing is expected to continue shifting toward the edge to reduce latency and bandwidth demands: https://www.mckinsey.com/industries/technology-media-and-telecommunications/our-insights/the-next-big-shifts-in-ai-workloads-and-hyperscaler-strategies
- Qualcomm highlights on-device AI as a way to use local context while improving privacy, personalization, and efficiency: https://www.qualcomm.com/news/onq/2023/12/ai-on-the-edge-generative-ai-technology-impacts-insights-and-predictions

---

## What MirrorNeuron Provides

| Capability | Purpose |
|---|---|
| **Durable execution** | Preserve workflow progress across crashes, retries, and restarts. |
| **Message-driven orchestration** | Coordinate agents, tools, sensors, and workflow nodes through explicit events. |
| **Adaptive routing** | Respond to signals, load, failures, and changing workflow state. |
| **Backpressure** | Prevent overloaded agents, tools, or local resources from destabilizing the system. |
| **Observability** | Inspect workflow state, events, messages, decisions, and execution progress. |
| **Blueprints** | Package useful AI workflows as reusable, repeatable templates. |
| **Edge/cloud flexibility** | Run near data while still integrating with cloud services when useful. |

---

## Core Concept

AI is moving from:

```text
prompt → response
```

to:

```text
goal → agents → tools → events → state → recovery → results
```

MirrorNeuron turns AI workflows into durable, observable, message-driven systems.

Instead of fragile pipelines:

```text
prompt → tool → output
```

MirrorNeuron executes durable workflow graphs:

```text
signals → workflow graph → controlled execution → observable system
```

Workflows are treated as first-class software artifacts:

- versioned
- testable
- stateful
- replayable
- observable
- extensible

---

## Architecture at a Glance

MirrorNeuron keeps the runtime intentionally small and composable.

```text
Sensors / users / devices / tools / models
                    │
                    ▼
          MirrorNeuron Runtime
    ┌──────────┬───────────┬────────────┬─────────┐
    │ router   │ executor  │ aggregator │ sensor  │
    └──────────┴───────────┴────────────┴─────────┘
                    │
                    ▼
      Durable workflow graph + state + events
                    │
                    ▼
      Edge node / private cluster / hybrid cloud
```

### Runtime primitives

| Primitive | Role |
|---|---|
| `router` | Routes messages between workflow nodes and agents. |
| `executor` | Runs bounded units of work. |
| `aggregator` | Coordinates intermediate and final results. |
| `sensor` | Ingests external events, signals, and triggers. |

Minimal primitives keep MirrorNeuron understandable while enabling complex orchestration patterns.

---

## Key Design Idea

### Logical Workers vs. Execution Leases

MirrorNeuron separates workflow state from execution capacity.

| Concept | Meaning |
|---|---|
| **Logical Worker** | Lightweight state holder for a workflow node or agent. |
| **Execution Lease** | Bounded compute capacity used when actual execution is needed. |

This separation enables:

- efficient resource utilization
- safe execution isolation
- adaptive scheduling
- backpressure under load
- scalable long-running workflows

For on-edge systems, this distinction is especially important: local compute is valuable, constrained, and often shared across agents, tools, sensors, models, and services.

---

## Available Today

MirrorNeuron is early, but already includes concrete runtime capabilities.

| Capability | Status |
|---|---|
| Core runtime | Available |
| Message-driven workflow execution | Available |
| CLI workflow launch | Available |
| Blueprint runner | Available |
| Local execution | Available |
| Clustered execution | Available |
| Persistence support | Available |
| Terminal monitoring | Available |
| Web UI | Ecosystem component |
| Python SDK | Ecosystem component |
| TypeScript SDK | Ecosystem component |

Detailed setup, configuration, and operating instructions live in the documentation repository:

- [Docs landing page](https://github.com/MirrorNeuronLab/mn-docs/blob/main/README.md)
- [Quickstart](https://github.com/MirrorNeuronLab/mn-docs/blob/main/quickstart.md)
- [Installation](https://github.com/MirrorNeuronLab/mn-docs/blob/main/installation.md)
- [Security model](https://github.com/MirrorNeuronLab/mn-docs/blob/main/security.md)

---

## Who Is MirrorNeuron For?

| Audience | Why it matters |
|---|---|
| **AI application developers** | Build agents that survive failures and run beyond one request. |
| **Robotics / physical AI teams** | Coordinate local workflows close to sensors, machines, and real-time signals. |
| **Enterprise AI teams** | Keep sensitive workflows inside private or regulated environments. |
| **Research labs** | Run long-running scientific agents with state, checkpoints, and recovery. |
| **Platform teams** | Provide a reusable runtime layer for AI workflows across teams and products. |
| **Open-source builders** | Contribute to an ambitious infrastructure layer for adaptive AI systems. |

---

## Beachhead Use Cases

MirrorNeuron is especially suited for AI systems where cloud-only execution is not enough.

| Use Case | Why Edge Matters |
|---|---|
| **Scientific research agents** | Private data, long-running workflows, repeatable experiments. |
| **Drug discovery workflows** | Multi-step reasoning, tool calls, auditability, recovery. |
| **Robotics / physical AI** | Low latency, local sensors, safety boundaries. |
| **Manufacturing / industrial AI** | Private site data, unreliable networks, real-time signals. |
| **Enterprise agents** | Data ownership, policy control, internal system integration. |
| **Financial workflows** | Audit trails, deterministic execution, compliance-sensitive data. |

---

## Why Developers Care

MirrorNeuron is designed to make useful AI workflows easier to build, run, and debug.

- one-command install
- reusable blueprints
- CLI-first workflow launch
- local development support
- observable events and workflow state
- Python and TypeScript SDK ecosystem
- clear path from demo workflow to repeatable system

---

## Why Tech Leads Care

MirrorNeuron is designed for teams that need AI workflows to behave like production software.

- explicit workflow graphs
- durable state
- replayable execution
- observable events
- bounded execution capacity
- backpressure under load
- edge/cloud deployment flexibility
- SDK, API, and CLI ecosystem

---

## Investment Thesis

AI is moving from centralized demos into operational systems: robots, labs, factories, private enterprise networks, developer machines, local clusters, and edge devices.

These systems need more than models. They need infrastructure for orchestration, state, recovery, observability, policy, and control.

MirrorNeuron starts with durable AI workflow execution and expands toward a broader **control plane for on-edge AI systems**.

---

## What MirrorNeuron Is — and Is Not

MirrorNeuron is **not** just another prompt framework.

| MirrorNeuron is not | MirrorNeuron is |
|---|---|
| A prompt wrapper | A durable runtime for AI systems |
| A batch scheduler | A message-driven workflow engine |
| A demo-only agent framework | Infrastructure for long-running agents |
| A black-box automation tool | Observable, controllable orchestration |
| A cloud-only platform | Edge-ready AI infrastructure |

MirrorNeuron is designed to sit underneath agent frameworks, tools, SDKs, and interfaces as the execution layer for reliable AI workflows.

---

## Comparison

| Project | Primary Focus | Strength | Gap MirrorNeuron Targets |
|---|---|---|---|
| **LangGraph** | Agent/workflow graphs | Easy LLM graph composition | Less focused on durable on-edge execution and resource-aware orchestration |
| **Temporal** | Durable workflows | Production-grade reliability | Not designed specifically for adaptive AI agents or edge-native execution |
| **Airflow** | Batch/data workflows | Mature scheduling ecosystem | Not ideal for adaptive, message-driven, long-running AI agents |
| **Ray** | Distributed compute | Scalable parallel execution | Less opinionated around durable workflow control, replay, and agent orchestration |
| **MirrorNeuron** | On-edge AI infrastructure | Durable, adaptive, message-driven AI runtime | Early ecosystem, actively evolving |

---

## Ecosystem

MirrorNeuron is a modular open-source ecosystem.

| Component | Description |
|---|---|
| 🧠 **MirrorNeuron Core Runtime** | https://github.com/MirrorNeuronLab/MirrorNeuron |
| 🔌 **mn-api** | REST gateway for HTTP access — https://github.com/MirrorNeuronLab/mn-api |
| 💻 **mn-cli** | CLI for workflow and job lifecycle management — https://github.com/MirrorNeuronLab/mn-cli |
| 🌐 **mn-web-ui** | Visual workflow dashboard — https://github.com/MirrorNeuronLab/mn-web-ui |
| 🐍 **mn-python-sdk** | Python SDK for agents and integrations — https://github.com/MirrorNeuronLab/mn-python-sdk |
| 🟦 **mn-ts-sdk** | TypeScript SDK — https://github.com/MirrorNeuronLab/mn-ts-sdk |
| 📦 **mn-deploy** | Deployment tooling — https://github.com/MirrorNeuronLab/mn-deploy |
| 🧪 **mn-system-tests** | End-to-end testing — https://github.com/MirrorNeuronLab/mn-system-tests |
| 🏗 **mirrorneuron-blueprints** | Reusable AI workflow examples — https://github.com/MirrorNeuronLab/mirrorneuron-blueprints |
| 📚 **mn-docs** | Documentation, architecture notes, and guides — https://github.com/MirrorNeuronLab/mn-docs |

---

## Roadmap Themes

MirrorNeuron is an ambitious open-source infrastructure project. The long-term goal is to become a shared runtime foundation for adaptive AI systems.

Current roadmap themes include:

- richer blueprint catalog
- stronger workflow replay and debugging
- high-availability runtime patterns
- advanced scheduling and backpressure policies
- artifact and memory integrations
- deeper SDK support
- production-grade observability
- edge deployment patterns
- community-driven examples and benchmarks

---

## Documentation

The dedicated documentation repository is organized around fast first success, safe operation, and contributor onboarding:

| Goal | Start here |
|---|---|
| Install and run the first workflow | [Quickstart](https://github.com/MirrorNeuronLab/mn-docs/blob/main/quickstart.md) |
| Set up local dependencies | [Installation](https://github.com/MirrorNeuronLab/mn-docs/blob/main/installation.md) |
| Learn the runtime model | [Runtime Architecture](https://github.com/MirrorNeuronLab/mn-docs/blob/main/runtime-architecture.md) |
| Use the CLI | [CLI Reference](https://github.com/MirrorNeuronLab/mn-docs/blob/main/cli.md) |
| Build or run blueprints | [Blueprints and Skills](https://github.com/MirrorNeuronLab/mn-docs/blob/main/blueprints-and-skills.md) |
| Configure Redis failover | [Redis High Availability](https://github.com/MirrorNeuronLab/mn-docs/blob/main/redis-ha.md) |
| Operate safely | [Security Model](https://github.com/MirrorNeuronLab/mn-docs/blob/main/security.md) |
| Fix common failures | [Troubleshooting](https://github.com/MirrorNeuronLab/mn-docs/blob/main/troubleshooting.md) |

Full docs index:

**https://github.com/MirrorNeuronLab/mn-docs**

---

## Community

Join the community, share feedback, and help shape the runtime for adaptive on-edge AI workflows.

- Discord: https://discord.com/invite/XmSQqFEz
- Slack: https://mirrorneuron.slack.com/ssb/redirect
- Website: https://mirrorneuron.io

---

## Contributing

Contributions are welcome across the ecosystem.

Good places to contribute:

- runtime primitives
- blueprints and examples
- SDK integrations
- documentation
- tests and benchmarks
- design discussions
- edge deployment examples

Start with:

- [Contributing guide](https://github.com/MirrorNeuronLab/mn-docs/blob/main/contributing.md)
- [Testing guide](https://github.com/MirrorNeuronLab/mn-docs/blob/main/testing.md)
- [Documentation style guide](https://github.com/MirrorNeuronLab/mn-docs/blob/main/documentation-style.md)
- [Blueprints and Skills](https://github.com/MirrorNeuronLab/mn-docs/blob/main/blueprints-and-skills.md)

---

## Security

If you believe you have found a vulnerability, please do **not** disclose exploit details in a public issue.

Read the operator-facing security model before running third-party bundles, passing secrets into workers, or exposing a cluster:

**https://github.com/MirrorNeuronLab/mn-docs/blob/main/security.md**

Use the repository security page for vulnerability reports:

**https://github.com/MirrorNeuronLab/MirrorNeuron/security**

---

## License

MIT License
