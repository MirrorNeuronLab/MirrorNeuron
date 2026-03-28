# Development Guide

This guide is for contributors and integrators working on MirrorNeuron itself.

## Project structure

Important files and directories:

- [mix.exs](/Volumes/1TB/Personal_projects/MirrorNeuron/mix.exs)
- [lib/mirror_neuron.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron.ex)
- [lib/mirror_neuron/runtime](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/runtime)
- [lib/mirror_neuron/builtins](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/builtins)
- [lib/mirror_neuron/sandbox](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/sandbox)
- [lib/mirror_neuron/execution](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/execution)
- [lib/mirror_neuron/monitor.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/monitor.ex)
- [test](/Volumes/1TB/Personal_projects/MirrorNeuron/test)

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

- [agent.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/agent.ex)
- [agent_template.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/agent_template.ex)
- [agent_templates/accumulator.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/agent_templates/accumulator.ex)

For operational tooling, prefer building on:

- `MirrorNeuron.list_jobs/1`
- `MirrorNeuron.job_details/2`
- `MirrorNeuron.cluster_overview/1`

instead of reaching directly into Redis.

## Documentation expectations

If you add a user-visible feature, update:

- [README.md](/Volumes/1TB/Personal_projects/MirrorNeuron/README.md)
- at least one page under [/Volumes/1TB/Personal_projects/MirrorNeuron/docs](/Volumes/1TB/Personal_projects/MirrorNeuron/docs)
- [docs/api.md](/Volumes/1TB/Personal_projects/MirrorNeuron/docs/api.md) if the feature changes public inspection or control APIs
