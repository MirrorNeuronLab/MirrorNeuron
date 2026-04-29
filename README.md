# MirrorNeuron

**A simple, durable runtime for controllable AI workflows.**

MirrorNeuron enables teams to build **reliable, controllable AI workflows**—with the rigor of systems like Temporal, but the simplicity and accessibility of modern agent frameworks.

Today’s AI systems are powerful, but often lack **determinism, observability, and control**. MirrorNeuron addresses this gap by providing a runtime where workflows are:
- structured and verifiable
- durable and fault-tolerant
- easy to adopt by small teams or even individuals

Think of it as:
> **Temporal for muti agents AI workflows — but as easy to adopt as OpenClaw.**


## Community

- Slack: https://mirrorneuron.slack.com/ssb/redirect  
- Discord: https://discord.com/invite/XmSQqFEz


---

## 🚀 The MirrorNeuron Ecosystem

This repository contains the **core Elixir/BEAM runtime and gRPC server**.

It is responsible for:
- orchestration
- supervision
- message routing
- clustering
- persistence


## Repositories

| Component | Description |
|----------|-------------|
| 🧠 MirrorNeuron (Core Runtime) | https://github.com/MirrorNeuronLab/MirrorNeuron — Event-driven orchestrator built on Erlang/OTP |
| 🔌 mn-api | https://github.com/MirrorNeuronLab/mn-api — REST gateway for HTTP access |
| 💻 mn-cli | https://github.com/MirrorNeuronLab/mn-cli — CLI for job lifecycle management |
| 🌐 mn-web-ui | https://github.com/MirrorNeuronLab/mn-web-ui — Visual workflow dashboard |
| 🐍 mn-python-sdk | https://github.com/MirrorNeuronLab/mn-python-sdk — Python SDK for agents |
| 🟦 mn-ts-sdk | https://github.com/MirrorNeuronLab/mn-ts-sdk — TypeScript SDK |
| 📦 mn-deploy | https://github.com/MirrorNeuronLab/mn-deploy — Deployment tooling |
| 🧪 mn-system-tests | https://github.com/MirrorNeuronLab/mn-system-tests — End-to-end testing |
| 🏗️ mn-blueprints | https://github.com/MirrorNeuronLab/mirrorneuron-blueprints — Reusable workflow examples |


Examples:
- https://github.com/MirrorNeuronLab/mirrorneuron-blueprints


---

## ✨ Why MirrorNeuron?

Modern AI workflows need more than prompts and tools. They need:

- **Control** — predictable execution paths and policies  
- **Durability** — workflows that survive failures and restarts  
- **Observability** — inspect and debug every step  
- **Scalability** — from laptop to cluster seamlessly  

MirrorNeuron delivers these while remaining:

- **Lightweight** — no heavy infrastructure required  
- **Composable** — minimal primitives, maximum flexibility  
- **Accessible** — usable by individuals and small teams  

---

## 🧠 Core Ideas

### Runtime primitives

MirrorNeuron keeps the runtime intentionally small:

- `router`
- `executor`
- `aggregator`
- `sensor`

This minimal set ensures:
- composability
- clarity
- long-term maintainability

---

### Logical workers vs execution leases

MirrorNeuron separates:

- **logical workers** → lightweight BEAM processes holding workflow state  
- **execution leases** → limited sandbox capacity for actual execution  

This design:
- avoids unnecessary sandbox creation  
- enables efficient resource utilization  
- scales naturally under load  

---

### Message-driven workflows

Workflows are defined as graph bundles:

```
job-folder/
  manifest.json
  payloads/
```

- `manifest.json`
  - defines nodes, edges, entrypoints, and policies  
  - `agent_type` selects runtime primitive  
  - `type` selects behavior template (default: generic)  

- `payloads/`
  - contains execution code and artifacts  

---

## ⚡ Quickstart

Install:

```
curl -fsSL https://raw.githubusercontent.com/MirrorNeuronLab/MirrorNeuron/main/install.sh | bash
```

Run a workflow:

```
git clone https://github.com/MirrorNeuronLab/mirrorneuron-blueprints.git
cd mirrorneuron-blueprints

mn validate research_flow
mn run research_flow
mn monitor
```

---

## 🛠 CLI Commands

```
./mn validate <job-folder>
./mn run <job-folder>
./mn node list
./mn job inspect <job_id>
./mn job list [--live]
./mn events <job_id>
./mn monitor
```

---

## 🧩 Cluster and Monitoring

MirrorNeuron supports:
- local execution
- multi-node clustering
- production deployment patterns

---

## 🔌 Public API

MirrorNeuron exposes APIs for:
- monitoring
- control
- automation
- integrations

---

## 📚 Documentation

All documentation has been moved to:

https://github.com/MirrorNeuronLab/mn-docs

---

## 📦 Current Capabilities

### Available today

- local execution  
- clustered execution  
- Redis-backed persistence  
- OpenShell executor isolation  
- terminal monitoring  

### In progress

- high availability and failover  
- richer sensor semantics  
- artifact storage integration  
- advanced scheduling policies  

---

## 🧰 Multi-Component Workspace Notes

When this repository is checked out inside `mirror-neuron-set`, it may sit beside separately installable components:

- `mn-api`: Python REST gateway
- `mn-cli`: Python CLI
- `mn-python-sdk`: Python gRPC SDK
- `mn-ts-sdk`: TypeScript SDK
- `mn-web-ui`: React/Vite dashboard
- `mn-skills`: individually installable skill packages
- `mn-blueprints`: reusable blueprint catalog
- `mn-system-tests`: opt-in integration and e2e tests

Keep those components independently installable and upgradeable. Cross-component behavior should use stable interfaces: gRPC, REST, CLI commands, manifests, package dependencies, and environment variables.

All runtime/config overrides should use the `MIRROR_NEURON_` prefix. Common core variables include:

- `MIRROR_NEURON_ENV`
- `MIRROR_NEURON_GRPC_PORT`
- `MIRROR_NEURON_REDIS_URL`
- `MIRROR_NEURON_REDIS_NAMESPACE`
- `MIRROR_NEURON_COOKIE`
- `MIRROR_NEURON_TEMP_DIR`
- `MIRROR_NEURON_DEFAULT_MAX_AGENT_QUEUE_DEPTH`
- `MIRROR_NEURON_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK`
- `MIRROR_NEURON_DEFAULT_AGENT_QUEUE_LOW_WATERMARK`
- `MIRROR_NEURON_RESOURCE_ADMISSION_ENABLED`
- `MIRROR_NEURON_MAX_CPU_LOAD_RATIO`
- `MIRROR_NEURON_MAX_MEMORY_USED_RATIO`
- `MIRROR_NEURON_MAX_GPU_UTILIZATION_RATIO`
- `MIRROR_NEURON_MAX_GPU_MEMORY_USED_RATIO`

Useful workspace test commands:

```
python3 scripts/test_all.py --fast
python3 scripts/test_all.py --unit
python3 scripts/test_all.py --blueprints
python3 scripts/test_all.py --runtime-e2e
python3 scripts/test_all.py --security
python3 scripts/test_all.py --integration --live
python3 scripts/test_all.py --e2e --live
```

Blueprints are trusted executable code. Review a blueprint before running it with credentials or host access.

---

## 🧠 Architecture Summary

MirrorNeuron is not a batch scheduler.

It is a **durable, message-driven runtime for AI workflows** that:

- separates orchestration from execution  
- treats workflows as structured graphs  
- enables controlled, observable execution  

---

## 🤝 Contributing

Contributions are welcome. See documentation:

https://github.com/MirrorNeuronLab/mn-docs

---

## 📄 License

MIT License
