# MirrorNeuron

**The simple durable runtime for AI workflows.**

MirrorNeuron is the simplest way to run durable AI workflows. Run your first AI workflow in minutes, then build multi-agent workflows in your preferred language with normal code—without Airflow DAG sprawl or Temporal cluster complexity.

Think of it as the "Ollama for durable workflows": powerful enough for production, but dead simple to adopt and run.

---

## 🚀 The MirrorNeuron Ecosystem

This repository (`MirrorNeuron`) contains **only the core Elixir/BEAM runtime and gRPC server**. It handles orchestration, supervision, message routing, clustering, and persistence.

All interfaces, SDKs, deployments, and examples have been extracted into their own dedicated repositories:

| Component | Description |
|-----------|-------------|
| 🧠 **[MirrorNeuron (This Repo)](https://github.com/MirrorNeuronLab/MirrorNeuron)** | The core runtime. Event-driven, message-oriented orchestrator built on Erlang/OTP. |
| 🔌 **[mn-api](https://github.com/MirrorNeuronLab/mn-api)** | The RESTful HTTP Gateway. Allows external microservices to interact with the cluster via HTTP instead of gRPC. |
| 💻 **[mn-cli](https://github.com/MirrorNeuronLab/mn-cli)** | The official Command Line Interface (`mn`). Built with Typer and Rich for elegant job lifecycle management. |
| 🌐 **[mn-web-ui](https://github.com/MirrorNeuronLab/mn-web-ui)** | A modern Web Dashboard built with React Flow to visualize jobs, agents, and real-time logs. |
| 🐍 **[mn-python-sdk](https://github.com/MirrorNeuronLab/mn-python-sdk)** | Python SDK for writing agents, executors, and interacting with the runtime. |
| 🟦 **[mn-ts-sdk](https://github.com/MirrorNeuronLab/mn-ts-sdk)** | TypeScript SDK for writing agents and interacting with the runtime natively in Node/TypeScript. |
| 📦 **[mn-deploy](https://github.com/MirrorNeuronLab/mn-deploy)** | Deployment scripts, installation wrappers, and system configuration for standing up MirrorNeuron clusters. |
| 🧪 **[mn-system-tests](https://github.com/MirrorNeuronLab/mn-system-tests)** | End-to-end integration and scale testing suites across the entire ecosystem. |
| 🏗️ **[mn-blueprints](https://github.com/MirrorNeuronLab/mirrorneuron-blueprints)** | Reusable workflow examples: research loops, marketing automation, finance risk monitoring, and edge workflows. |

---

## ✨ Why MirrorNeuron?

- **Simplicity First:** Get the reliability of durable execution without the massive infrastructure tax.
- **Language Agnostic Execution:** BEAM handles orchestration, but your heavy execution path (Python, TS, Shell) runs in isolated `executor` nodes via OpenShell.
- **Small Primitive Set:** Built around four simple primitives: `router`, `executor`, `aggregator`, `sensor`.
- **Bounded Capacity:** Shared OpenShell sandbox reuse per job per runtime node, controlled by executor leases and pools.
- **Clustered out of the box:** BEAM cluster support with `libcluster` and `Horde`, persisting to Redis.

## ⚡ Quickstart

You can install the entire MirrorNeuron ecosystem using the one-line install script on macOS, Linux, or WSL.

```bash
curl -fsSL https://raw.githubusercontent.com/MirrorNeuronLab/MirrorNeuron/main/install.sh | bash
```

*Note: You must have Erlang and Elixir installed on your system. If missing, the script will guide you.*

Then, clone some blueprints and run your first workflow:

```bash
git clone https://github.com/MirrorNeuronLab/mirrorneuron-blueprints.git
cd mirrorneuron-blueprints

mn validate research_flow
mn run research_flow
mn monitor
```

## 📖 Documentation

If you are developing the core runtime, these docs live right here:

1. [Runtime Architecture](docs/runtime-architecture.md)
2. [Reliability Guide](docs/reliability.md)
3. [API Reference (gRPC)](docs/api.md)
4. [Development Guide](docs/development.md)

*For SDK, CLI, or API documentation, please see their respective repositories.*

## 🧠 Core Architecture

MirrorNeuron is not trying to be a general-purpose batch scheduler. It distinguishes between:

- **Logical workers:** Cheap BEAM processes that hold workflow state.
- **Execution leases:** Scarce sandbox capacity used by `executor` nodes.

This separation is why the runtime scales better than "launch one sandbox for every worker immediately." Domain-specific agent logic belongs in job bundles or user SDKs, not in the runtime kernel.

## 🤝 Contributing

We welcome contributions! If you are working on the core runtime, please see our [Development Guide](docs/development.md). 

MirrorNeuron is available under the [MIT License](LICENSE).
