# MirrorNeuron Core

MirrorNeuron Core is the Elixir/OTP runtime for durable, message-driven AI
workflows. It schedules workflow agents, routes messages, records events,
persists job state through Redis, and exposes gRPC services.

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
