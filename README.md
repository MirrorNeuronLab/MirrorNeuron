# MirrorNeuron Core

MirrorNeuron Core is the Elixir/OTP runtime at the center of the MirrorNeuron
project: a durable, message-driven runtime for building AI workflows that need
to keep running, recover cleanly, and coordinate work across agents and
services.

Core schedules workflow agents, routes messages, records events, persists job
state through Redis, manages clustered runtime behavior, and exposes gRPC
services for the surrounding ecosystem. It is the runtime layer used by the
MirrorNeuron CLI, Python SDK, API services, Otterdesk app, blueprints, agents,
and skills.

If you are new to the project, start with the documentation repo:
[MirrorNeuronLab/mn-docs](https://github.com/MirrorNeuronLab/mn-docs). It
explains the overall architecture, component responsibilities, runtime model,
deployment expectations, and how the core runtime fits with the rest of the
MirrorNeuron stack.

> Important: MirrorNeuron is in alpha. APIs, manifests, release artifacts, and
> ecosystem components may change between releases.

## Quick Start

Install dependencies and run the core test suite:

```bash
mix deps.get
mix test
```

For Redis-backed runtime tests, start Redis first:

```bash
docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7
mix test
```

## Details

- [MirrorNeuron Documentation](https://github.com/MirrorNeuronLab/mn-docs)
- [MirrorNeuron Component Guide](../mn-docs/component-guide.md#mirrorneuron-core)
- [Runtime Architecture](../mn-docs/runtime-architecture.md)
- [Cluster Architecture](../mn-docs/cluster_architecture.md)
- [Reliability Guide](../mn-docs/reliability.md)
- [Security Model](../mn-docs/security.md)

## Common Paths

| Path | Purpose |
| --- | --- |
| `lib/mirror_neuron/` | Core runtime modules. |
| `lib/mirror_neuron_grpc/` | gRPC service implementation. |
| `proto/` | Protobuf contracts. |
| `config/` | Runtime configuration. |
| `tests/` | Unit, regression, API, and e2e tests. |
