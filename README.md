# 🧠 MirrorNeuron: On-Edge AI Infrastructure

### Durable Runtime for Adaptive, Controllable AI Workflows

MirrorNeuron is open-source **on-edge AI infrastructure**: a durable runtime and control plane for long-running agents, workflow graphs, and AI systems that need to run close to data, users, sensors, robots, devices, and private environments.

It is designed for the next wave of AI applications: **local-first, cloud-aware, privacy-sensitive, event-driven, and adaptive**.

<!-- start-badges -->
[![License](https://img.shields.io/badge/License-MIT-blue)](https://github.com/MirrorNeuronLab/MirrorNeuron/blob/main/LICENSE)
[![Security Policy](https://img.shields.io/badge/Security-Report%20a%20Vulnerability-red)](https://github.com/MirrorNeuronLab/MirrorNeuron/security/policy)
[![Project Status](https://img.shields.io/badge/status-alpha-orange)](https://github.com/MirrorNeuronLab/mn-docs)
[![On-Edge AI](https://img.shields.io/badge/On--Edge%20AI-Infrastructure-purple)](https://mirrorneuron.io)
[![Docs](https://img.shields.io/badge/Docs-mn--docs-blue)](https://github.com/MirrorNeuronLab/mn-docs)
[![Discord](https://img.shields.io/badge/Discord-Join-7289da)](https://discord.com/invite/XmSQqFEz)
[![Website](https://img.shields.io/badge/Website-mirrorneuron.io-black)](https://mirrorneuron.io)
<!-- end-badges -->

---

## What is MirrorNeuron?

MirrorNeuron is a **durable execution runtime for adaptive AI workflows**.

It helps teams build AI systems that are more than prompt chains: systems that can run for long periods, coordinate multiple agents, recover from failures, observe every step, and adapt to changing conditions.

> Think **Temporal for AI workflows** — but lighter, agent-native, and designed for message-driven multi-agent systems.

Modern AI systems are becoming **stateful, event-driven, long-running software**. MirrorNeuron provides the runtime layer they need:

- **Durability** — workflows survive crashes, retries, and restarts
- **Control** — execution follows explicit policies, boundaries, and routing logic
- **Observability** — messages, state transitions, and decisions can be inspected
- **Adaptivity** — workflows respond to signals, load, failures, and new evidence
- **Edge-readiness** — AI workflows can run close to data, devices, and private environments

> [!IMPORTANT]
> MirrorNeuron is currently **alpha software**. Interfaces may change as the ecosystem evolves. We are sharing it early to invite feedback, contributors, and real-world experimentation.

---

## Why On-Edge AI Infrastructure?

AI is moving from centralized demos into operational systems that live where work happens:

- enterprise private networks
- local edge servers
- robotics and physical AI platforms
- factories, labs, clinics, vehicles, and field operations
- developer machines and private clusters
- hybrid systems that combine local execution with cloud services

This shift creates a new infrastructure problem.

Models may be able to run locally, but **production AI still needs a runtime**: something that can coordinate agents, preserve state, recover from failures, enforce policy, expose observability, and adapt to changing conditions.

### Why now?

On-edge AI infrastructure matters because:

| Driver | Why it matters |
|---|---|
| **Privacy** | Sensitive data often needs to stay inside a device, site, lab, enterprise network, or regulated environment. |
| **Latency** | Robots, industrial systems, interactive agents, and real-time workflows cannot always wait for cloud round trips. |
| **Bandwidth** | Sending every sensor stream, video frame, tool call, and intermediate state to the cloud is expensive and brittle. |
| **Reliability** | Edge systems must continue operating when networks are slow, intermittent, or unavailable. |
| **Ownership** | Teams increasingly want control over where models, agents, tools, and workflow state actually run. |
| **Opportunity** | As inference moves closer to data, the bottleneck shifts from model access to orchestration, reliability, and control. |

MirrorNeuron is built for this opportunity: an open-source runtime foundation for **edge-native AI systems**.

### The infrastructure opportunity

Just as cloud-native applications required orchestration layers, on-edge AI systems need orchestration for:

- long-running agents
- workflow state
- local compute resources
- tool execution
- event streams
- retries and recovery
- observability and auditability
- hybrid edge/cloud coordination

MirrorNeuron aims to become that open, durable, and adaptive runtime layer.

---

## Quick Install

```bash
curl -fsSL https://mirrorneuron.io/install.sh | bash
```

---

## Launch Something Useful

Run a real blueprint with one command:

```bash
mn blueprint run science_drug_discovery_deamon
```

This is intended to demonstrate MirrorNeuron as a runtime for useful, long-running AI workflows — not just a toy prompt demo.

It showcases:

- multi-agent coordination
- durable workflow execution
- adaptive orchestration
- observable state and progress
- a blueprint-oriented path from demo to repeatable workflow

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

## Adaptive Runtime Model

MirrorNeuron keeps the runtime intentionally small and composable.

```text
External signals / users / devices / tools / models
              │
              ▼
      MirrorNeuron Runtime
  ┌──────────┬───────────┬────────────┬─────────┐
  │ router   │ executor  │ aggregator │ sensor  │
  └──────────┴───────────┴────────────┴─────────┘
              │
              ▼
 Durable, observable, adaptive workflow graph
```

### Runtime primitives

| Primitive | Role |
|---|---|
| `router` | Routes messages between workflow nodes and agents. |
| `executor` | Runs bounded units of work. |
| `aggregator` | Coordinates intermediate and final results. |
| `sensor` | Ingests external events, signals, and triggers. |

This minimal model keeps MirrorNeuron understandable while leaving room for powerful orchestration patterns.

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

For on-edge systems, this distinction is especially important: local compute is valuable, constrained, and often shared across agents, tools, sensors, and services.

---

## Edge-Native by Design

MirrorNeuron does not assume everything runs only in the cloud or only on a device. It is designed for **hybrid AI systems**.

```text
Edge runtime + local agents + private data + cloud services when useful
```

That means MirrorNeuron can support patterns such as:

- local workflow execution with cloud model calls
- local model inference with remote observability
- private-network agents with controlled external integrations
- edge blueprints that coordinate sensors, tools, and executors
- distributed workflows across developer machines, edge nodes, and clusters

The goal is not to replace the cloud. The goal is to make AI workflows **portable, controllable, and durable wherever they run**.

---

## What MirrorNeuron Provides

| Capability | Purpose |
|---|---|
| **Durable execution** | Keep progress across failures, retries, and restarts. |
| **Message-driven orchestration** | Coordinate agents and workflow nodes through explicit events. |
| **Adaptive routing** | Respond to signals, load, failures, and changing workflow state. |
| **Backpressure** | Prevent overloaded agents or tools from destabilizing the system. |
| **Observability** | Inspect workflow state, events, messages, and execution progress. |
| **Blueprints** | Package repeatable AI workflows as reusable templates. |
| **Edge/cloud flexibility** | Run near data while still integrating with cloud services when useful. |

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

| System / Layer | Great for | Gap MirrorNeuron targets |
|---|---|---|
| Agent frameworks | Rapid agent prototyping | Runtime durability, recovery, observability, and edge orchestration |
| LangGraph-style workflows | Graph-based agent logic | Production runtime guarantees and long-running execution semantics |
| Temporal | Durable business workflows | AI-native workflow graphs, agent patterns, and edge-oriented execution |
| Kubernetes | Deploying containers | Application-level workflow state, message routing, and agent coordination |
| Cloud AI APIs | Accessing powerful models | Local/private execution control, adaptive orchestration, and workflow durability |

---

## Example Use Cases

### Scientific discovery agents

Coordinate long-running research workflows such as literature review, hypothesis generation, simulation, ranking, validation, and report synthesis.

### Robotics and physical AI

Run workflows that combine planning, simulation, validation, execution, monitoring, and recovery.

### Industrial and field operations

Coordinate agents close to sensors, machines, devices, and local operational data.

### Private enterprise AI

Run agent workflows inside secure environments where data governance, auditability, and control matter.

### Finance and compliance

Build auditable multi-step decision pipelines where every decision, retry, and state transition can be inspected.

### Developer and research automation

Create persistent agents that can run, pause, resume, observe signals, and continue work across sessions.

---

## When to Use MirrorNeuron

Use MirrorNeuron when:

- workflows run longer than a single request
- agents depend on each other
- failures are costly or hard to debug
- workflow state must be observable or recoverable
- sensitive data should remain local or private
- local/edge execution matters
- you need repeatable blueprints, not one-off scripts

MirrorNeuron may be unnecessary when:

- the task is a simple prompt-response interaction
- no state, retry, observability, or recovery is needed
- a small script is enough

---

## Repository Role

This repository contains the **core MirrorNeuron runtime**.

It is responsible for:

- orchestration
- supervision
- message routing
- workflow execution
- clustering foundations
- persistence foundations

Operational details, deployment guides, CLI references, SDK usage, and advanced architecture notes live in the documentation repository.

---

## Documentation

All detailed documentation has moved to:

**https://github.com/MirrorNeuronLab/mn-docs**

Recommended starting points:

| Topic | Where to go |
|---|---|
| Getting started | [`mn-docs`](https://github.com/MirrorNeuronLab/mn-docs) |
| Architecture | [`mn-docs`](https://github.com/MirrorNeuronLab/mn-docs) |
| CLI reference | [`mn-docs`](https://github.com/MirrorNeuronLab/mn-docs) |
| SDK usage | [`mn-docs`](https://github.com/MirrorNeuronLab/mn-docs) |
| Deployment | [`mn-docs`](https://github.com/MirrorNeuronLab/mn-docs) |
| Blueprints | [`mirrorneuron-blueprints`](https://github.com/MirrorNeuronLab/mirrorneuron-blueprints) and [`mn-docs`](https://github.com/MirrorNeuronLab/mn-docs) |

---

## Ecosystem

MirrorNeuron is designed as a modular open-source ecosystem.

| Component | Description |
|---|---|
| [MirrorNeuron Core](https://github.com/MirrorNeuronLab/MirrorNeuron) | Core runtime and orchestration engine. |
| [mn-docs](https://github.com/MirrorNeuronLab/mn-docs) | Documentation, guides, and architecture notes. |
| [mn-api](https://github.com/MirrorNeuronLab/mn-api) | API gateway for HTTP integrations. |
| [mn-cli](https://github.com/MirrorNeuronLab/mn-cli) | Command-line interface for workflow lifecycle management. |
| [mn-web-ui](https://github.com/MirrorNeuronLab/mn-web-ui) | Web dashboard for workflow visibility and control. |
| [mn-python-sdk](https://github.com/MirrorNeuronLab/mn-python-sdk) | Python SDK for agents and integrations. |
| [mn-ts-sdk](https://github.com/MirrorNeuronLab/mn-ts-sdk) | TypeScript SDK for agents and integrations. |
| [mn-deploy](https://github.com/MirrorNeuronLab/mn-deploy) | Deployment tooling. |
| [mn-system-tests](https://github.com/MirrorNeuronLab/mn-system-tests) | End-to-end and integration testing. |
| [mirrorneuron-blueprints](https://github.com/MirrorNeuronLab/mirrorneuron-blueprints) | Reusable workflow examples and templates. |

---

## Roadmap Themes

MirrorNeuron is an ambitious open-source project. The long-term goal is to become a shared runtime foundation for adaptive, on-edge AI systems.

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

## Market Context

For broader context on why on-edge AI infrastructure is becoming important:

- [NVIDIA: What Is Edge AI and How Does It Work?](https://blogs.nvidia.com/blog/what-is-edge-ai/)
- [NVIDIA: Cloud vs. Edge Computing](https://blogs.nvidia.com/blog/difference-between-cloud-and-edge-computing/)
- [McKinsey: The next big shifts in AI workloads and hyperscaler strategies](https://www.mckinsey.com/industries/technology-media-and-telecommunications/our-insights/the-next-big-shifts-in-ai-workloads-and-hyperscaler-strategies)
- [Qualcomm: Edge-first AI for privacy and bandwidth](https://www.qualcomm.com/news/onq/2025/12/qualcomm-insight-platform-edge-ai-video-saas)

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
- edge deployment patterns

Start with the documentation repository:

**https://github.com/MirrorNeuronLab/mn-docs**

---

## Security

If you believe you have found a vulnerability, please do **not** disclose exploit details in a public issue.

Use the repository security page or contact the maintainers through the documented community channels while the security policy evolves:

**https://github.com/MirrorNeuronLab/MirrorNeuron/security**

---

## License

MIT License
