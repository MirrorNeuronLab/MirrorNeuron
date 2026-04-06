# MirrorNeuron Runtime Architecture

This document explains the runtime model behind MirrorNeuron and why the project now looks the way it does.

## Design goals

MirrorNeuron is not trying to replicate Airflow as a general-purpose data scheduler. It is a multi-agent runtime with a narrower job:

- keep orchestration and collaboration in BEAM
- let worker code run in safe isolated sandboxes
- support cross-node execution
- keep inter-agent communication event-driven and observable
- avoid turning the BEAM control plane into a pile of heavyweight OS processes

That last point drives most of the recent changes.

## What we borrowed from Airflow

The project intentionally borrows a few control-plane ideas from Airflow while avoiding Airflow's product shape.

- Small built-in primitive set instead of domain-specific agents
- Clear separation between author-time workflow definition and runtime execution
- Pools and slot accounting for heavyweight execution capacity
- Strong message and artifact boundaries between scheduler concerns and task payload concerns

Airflow's big lesson for this runtime is not "copy operators." It is "treat heavyweight execution capacity as scarce and schedule it explicitly."

## Control plane vs execution plane

MirrorNeuron now has a sharper two-layer model.

### Control plane

The control plane lives in BEAM:

- job orchestration
- message routing
- supervision
- persistence
- retries and backoff
- event history
- aggregation
- cluster coordination

These are all cheap, stateful, highly concurrent tasks that BEAM is excellent at.

### Execution plane

The execution plane lives in OpenShell:

- sandbox creation
- external process startup
- filesystem staging
- shell or Python command execution
- stdout and stderr capture
- sandbox isolation

This work is comparatively expensive. It should be bounded and scheduled, not launched without limit.

## Logical workers vs physical execution leases

This is the most important runtime distinction.

### Logical worker

A logical worker is a BEAM process representing workflow state:

- it can receive messages
- it can wait cheaply
- it can be retried
- it can emit events
- it may request external execution

### Physical execution lease

A physical execution lease is permission to consume sandbox capacity on the current node:

- one or more executor slots from a pool
- typically one OpenShell sandbox run
- expensive compared to a BEAM process

The runtime should be able to hold thousands of logical workers without starting thousands of sandboxes at once.

That is why executor nodes now go through `MirrorNeuron.Execution.LeaseManager`.

## Why the lease manager exists

Before this change, each executor agent launched OpenShell directly from its own process. That worked for small demos, but it broke down under large fan-out:

- gateway resets under launch pressure
- duplicate cleanup races
- OS subprocess pressure
- too many expensive execution attempts starting at once

The lease manager addresses that by making executor capacity explicit.

- Every executor requests a lease before running OpenShell.
- The lease manager grants or queues the request per node.
- Executors emit events when they request, acquire, and release leases.
- Capacity is configured with `MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY` or per-pool overrides.

This keeps BEAM lightweight while still allowing large logical graphs.

## Executor pools and slots

MirrorNeuron now supports local executor pools.

- default pool capacity comes from `MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY`
- named pools can be configured with `MIRROR_NEURON_EXECUTOR_POOL_CAPACITIES`

Examples:

```bash
export MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY=4
export MIRROR_NEURON_EXECUTOR_POOL_CAPACITIES="default=4,gpu=1,io=8"
```

Executor node config can request a pool and slot count:

```json
{
  "agent_type": "executor",
  "config": {
    "pool": "default",
    "pool_slots": 1
  }
}
```

At the moment, pools are enforced per runtime node. That means the cluster scales by adding nodes, each with its own bounded execution capacity.

## Message model

The message system is intentionally split into control-plane and payload-plane sections.

- `envelope`: runtime-owned routing and trace metadata
- `headers`: extensible routing and schema metadata
- `body`: application-owned payload
- `artifacts`: references to large externalized data
- `stream`: optional stream framing metadata

This keeps the runtime generic.

The runtime should understand enough to route and observe messages, but it should not need to parse every application payload to work correctly.

That also enables multi-language workers: Python and shell code consume the payload contract inside the sandbox, while BEAM only needs the stable envelope.

## Why artifacts matter

Passing large blobs directly between agents is a bad fit for a clustered runtime.

Instead, messages should stay small and carry:

- ids
- routing metadata
- schema references
- artifact references

This is the same core operational lesson many schedulers learn: small control messages scale much better than inline large payloads.

## Built-in primitives

MirrorNeuron keeps only a small runtime primitive set in core:

- `router`
- `executor`
- `aggregator`
- `sensor`

Why so small:

- runtime primitives stay reusable
- domain-specific agents belong in user code or examples
- the project stays focused on collaboration mechanics instead of shipping business personas

## Why executor code still supports Python and shell

The project is not BEAM-only in the sense of "all useful code must be Elixir." That would make the runtime less practical.

Instead:

- BEAM owns coordination
- OpenShell owns isolated execution
- worker payloads can be shell, Python, or other supported runtimes

That means a logical worker does not "become Python." It requests external execution when needed.

## Operational guidance

A healthy deployment usually looks like this:

- many logical workers
- modest executor concurrency per node
- more nodes added when more real execution capacity is needed

Example:

- 1000 logical workers
- 4 nodes
- 8 executor slots per node
- real concurrent sandbox count: 32

That is still a large multi-agent workload, but it does not overload a single OpenShell gateway.

## Current limitations

The current implementation improves the runtime boundary a lot, but a few things are still intentionally simple:

- executor pools are local to each node, not globally brokered
- there is no cluster-wide lease balancer yet
- sensor and deferred waiting primitives can still grow richer
- artifacts are modeled in messages, but there is not yet a full external artifact store abstraction

Those are good next steps, but the current runtime is already much closer to the intended design:

- BEAM as the lightweight orchestrator
- OpenShell as bounded worker execution
- message-driven collaboration across supervised logical workers
