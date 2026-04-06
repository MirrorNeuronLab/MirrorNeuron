# Development Guide

This guide is for contributors and integrators working on MirrorNeuron itself.

## Project structure

Important files and directories:

- [mix.exs](../mix.exs)
- [lib/mirror_neuron.ex](../lib/mirror_neuron.ex)
- [lib/mirror_neuron/runtime](../lib/mirror_neuron/runtime)
- [lib/mirror_neuron/builtins](../lib/mirror_neuron/builtins)
- [lib/mirror_neuron/sandbox](../lib/mirror_neuron/sandbox)
- [lib/mirror_neuron/execution](../lib/mirror_neuron/execution)
- [lib/mirror_neuron/monitor.ex](../lib/mirror_neuron/monitor.ex)
- [test](../test)

## Development loop

```bash
mix deps.get
mix format
mix test
mix escript.build
```

## Runtime design expectations

MirrorNeuron tries to keep a strict boundary:

- BEAM for orchestration
- OpenShell for isolated execution

That means new features should usually preserve:

- small control-plane messages
- explicit execution capacity
- durable job and agent inspection
- event-driven collaboration

## Built-in primitives

Core built-ins are intentionally small:

- `router`
- `executor`
- `aggregator`
- `sensor`

Avoid adding domain-specific “business agents” to the runtime core.

## Testing guidance

Some tests are pure unit tests.

Some tests require Redis:

```bash
docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7
mix test
```

For real sandbox behavior, you also need OpenShell running.

## Extending the platform

The best starting points are:

- [agent.ex](../lib/mirror_neuron/agent.ex)
- [agent_template.ex](../lib/mirror_neuron/agent_template.ex)
- [agent_templates.ex](../lib/mirror_neuron/agent_templates.ex)
- [agent_templates/generic.ex](../lib/mirror_neuron/agent_templates/generic.ex)
- [agent_templates/stream.ex](../lib/mirror_neuron/agent_templates/stream.ex)
- [agent_templates/map.ex](../lib/mirror_neuron/agent_templates/map.ex)
- [agent_templates/reduce.ex](../lib/mirror_neuron/agent_templates/reduce.ex)
- [agent_templates/batch.ex](../lib/mirror_neuron/agent_templates/batch.ex)

## Agent templates

Node manifests now use:

- `agent_type`
  Runtime primitive such as `router`, `executor`, `aggregator`, or `sensor`
- `type`
  Behavioral template such as `generic`, `stream`, `map`, `reduce`, or `batch`

If `type` is omitted, MirrorNeuron defaults it to `generic`.

Templates are intentionally lighter-weight than built-ins:

- built-ins define runtime mechanics
- templates define reusable behavior contracts for payload authors

Current compatibility rules:

- `router`: `generic`, `map`
- `executor`: `generic`, `stream`, `map`, `reduce`, `batch`
- `aggregator`: `generic`, `reduce`
- `sensor`: `generic`

For operational tooling, prefer building on:

- `MirrorNeuron.list_jobs/1`
- `MirrorNeuron.job_details/2`
- `MirrorNeuron.cluster_overview/1`

instead of reaching directly into Redis.

## Documentation expectations

If you add a user-visible feature, update:

- [README.md](../README.md)
- at least one page under [docs](../docs)
- [docs/api.md](api.md) if the feature changes public inspection or control APIs
