# Reliability Guide

This guide describes the practical reliability model currently implemented in MirrorNeuron.

It is intentionally modest:

- retry and replay where possible
- recover from runtime node loss without taking the whole job down
- keep work moving on the remaining healthy box
- document what still is not HA yet

MirrorNeuron is not a consensus-based control plane. It is closer to a durable, retryable workflow runtime with bounded sandbox execution.

## Reliability goals

The current design aims for:

- no single executor box causing total workflow failure by default
- replayable job shards instead of one giant irrecoverable task
- durable enough state to restart work after process or node loss
- at-least-once recovery with idempotent aggregation where needed

It does not yet aim for:

- exactly-once delivery
- leader election or quorum-based control
- Redis failover built into the runtime

## Mechanisms in use today

### Small units of work

The examples and scale harnesses break jobs into bounded chunks instead of one long-running worker.

That matters because recovery can replay one failed shard instead of redoing the whole workflow.

### Durable Redis-backed state

MirrorNeuron persists:

- job records
- job events
- agent snapshots
- cluster and job leases

Agent snapshots include:

- assigned node
- processed message count
- inflight message
- pending messages
- encoded local agent state
- heartbeat timestamp

This is the minimum durable state needed for replay-oriented recovery.

### Heartbeats

Agents periodically persist fresh snapshots with `last_heartbeat_at`.

The job coordinator runs health checks on an interval and uses missing or stale agents as a recovery signal.

### Dynamic Leader Election

MirrorNeuron now implements a Redis-backed leader election process.
The cluster automatically elects a leader by acquiring a `cluster:leader` lease. The leader node is responsible for cluster-wide health checks such as sweeping and recovering orphaned jobs (jobs whose coordinator crashed and haven't been picked up by Horde). 
If the leader node dies, another node automatically acquires the lease and assumes leadership, avoiding split-brain scenarios since Redis is the sole arbiter of truth.

### Retry and backoff

Executors already support bounded retry with backoff for transient sandbox failures.

Examples:

- OpenShell transport errors
- connection reset / closed
- transient sandbox startup failures

This is the first line of defense before cross-node recovery is needed.

### Redis reconnect and fallback commands

Redis operations now recover more gracefully from broken long-lived connections:

- reconnect the managed Redix client
- retry on connection failures
- fall back to a one-shot Redis connection when needed

This reduces cases where a single wedged Redis client would make an otherwise healthy node unusable.

### Distributed Coordinator with Lease

Job runners and coordinators are now managed dynamically by `Horde` across the peer cluster. 
They acquire a job lease in Redis.

That means:

- if a box dies during a job, `Horde` automatically schedules the coordinator on another available box.
- the new coordinator recognizes the existing job state via Redis, acquires the lease, and safely resumes work.
- the system dynamically re-balances control without being pinned to the original submission node.

### Agent recovery from persisted snapshots

When an agent disappears, MirrorNeuron can restart it from its last persisted snapshot.

Recovery uses:

- restored local state
- restored pending messages
- restored inflight message replay

This works both for:

- explicit recovery started by the coordinator
- agent redistribution/restart on the remaining node

### Replay of completed executor outputs

Executors now persist their last emitted output payload.

If an executor had already completed work before a node died, recovery can re-emit that logical result instead of silently losing it.

This closes an important gap where:

- the sandbox work had already finished
- but the downstream collector had not durably observed the result yet

### Aggregator dedupe for replayed executor results

The built-in aggregator now ignores duplicate results by `agent_id` when that field is present in the payload.

That makes replay safer for common fan-out/fan-in patterns such as:

- prime sweep workers
- single-result executor shards

This is an at-least-once reliability model with lightweight deduplication, not exactly-once delivery.

## What we verified

After the current reliability pass, the following were re-run successfully:

### Local e2e

- OpenShell worker demo
- prime sweep
- streaming peak detection
- LLM codegen/review loop

### Two-box cluster e2e

- prime sweep
- streaming peak detection
- LLM codegen/review loop

### Destructive failover test

We also verified a real two-box failover path:

1. start a cluster on box 1 and box 2
2. submit a larger prime fan-out job
3. wait until executors are actively running on box 2
4. kill the MirrorNeuron runtime on box 2 during execution
5. verify the job still completes on box 1

The dedicated harness is:

```bash
bash scripts/test_cluster_prime_failover_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --start 1000003 \
  --end 1006002
```

That test now completes successfully and emits recovery events.

## Failure model to expect

When an executor box dies:

- jobs should keep running if the coordinator is on a healthy box
- some work may be replayed
- throughput drops
- completion may take longer
- the result should still converge if replayable state exists

This is degraded service, not zero-impact failover.

## Current shortcomings

These are important to understand.

### Redis is still a single point of failure

Redis is the shared durable state store today.

If Redis is unavailable or corrupted:

- job state persistence is affected
- recovery data is affected
- event history is affected

Connection handling is more resilient now, but Redis itself is still a single point of failure.

### At-least-once, not exactly-once

Recovery can replay work or results.

That is why:

- executor outputs are replayable
- aggregators dedupe common duplicates

If you need exactly-once semantics, the current runtime is not there yet.

### Aggregator dedupe is intentionally simple

The built-in aggregator currently dedupes replayed executor results by `agent_id` when present.

That works well for one-result-per-worker patterns, but it is not a universal dedupe system for arbitrary multi-message streams.

### Redis client stability can still be noisy

The runtime now recovers from broken Redix connections much better, but under stress you may still see warning logs about closed connections.

In the current design, the fallback path keeps jobs completing successfully, but the logging may still be noisy.

### Node loss is covered better than full platform loss

We validated executor-node loss during active work.

We did not add comparable HA mechanisms yet for:

- Redis loss
- full seed/control node loss before or during submission
- multi-box network partitions with split-brain handling

## Practical guidance

If you want the most reliable behavior with the current runtime:

- keep work split into bounded shards
- prefer deterministic executor tasks
- design collectors/aggregators to tolerate replay
- keep Redis healthy and monitored
- treat box loss as capacity loss, not as a reason to restart the whole workflow

## Next likely improvements

If reliability becomes the next major focus, the most valuable next steps are:

- stale lease reclaim tied to node liveness
- event-driven completion instead of polling
- stronger durable mailbox semantics for critical messages
- deterministic coordinator ownership recorded in durable state
- HA Redis or an equivalent replicated metadata store
