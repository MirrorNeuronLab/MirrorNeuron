# Cluster Guide

This guide covers MirrorNeuron's peer-to-peer cluster architecture.

## Cluster Architecture

MirrorNeuron uses a **peer-to-peer, highly available cluster model**. It does not use a master-slave pattern. All runtime nodes run the exact same binary and are operationally symmetric. 

The cluster state is built on:
- **BEAM node distribution**: For transparent messaging
- **`libcluster`**: For discovering and joining peer nodes
- **`Horde`**: For distributed supervision of agents and jobs
- **Shared Redis**: For durable state, leader election, and job leasing

### Dynamic Leader Election

Critical cluster coordination, such as sweeping orphaned jobs, is handled by a dynamically elected leader.
1. The leader acquires a `cluster:leader` lease in Redis.
2. It refreshes this lease periodically.
3. If the leader node crashes or becomes unresponsive, the lease expires and another node immediately takes over leadership.

This failover-safe design ensures cluster coordination without tying the system to a single point of failure.

### Job Lease & Ownership

When a job is submitted, it is assigned a **Job Coordinator** process managed by `Horde`.
- The coordinator process acquires a lease in Redis indicating ownership of the job (`job:<job_id>`).
- If the node running the Job Coordinator dies, Horde detects the failure and schedules the coordinator on another peer.
- The new coordinator recognizes that the job already exists, waits for the previous lease to expire (if necessary), and then dynamically resumes the job by fetching its state from Redis.

## Required environment

All runtime boxes must agree on:

- `MIRROR_NEURON_COOKIE`
- `MIRROR_NEURON_CLUSTER_NODES`
- Redis location

Typical values:

```bash
export MIRROR_NEURON_COOKIE="mirrorneuron"
export MIRROR_NEURON_CLUSTER_NODES="mn1@192.168.4.29,mn2@192.168.4.35"
export MIRROR_NEURON_REDIS_URL="redis://192.168.4.29:6379/0"
```

## Recommended dev-mode networking

Use fixed distribution ports in dev mode:

```bash
export ERL_AFLAGS="-kernel inet_dist_listen_min 4370 inet_dist_listen_max 4370"
export MIRROR_NEURON_DIST_PORT="4370"
```

This makes failures much easier to reason about than random dynamic ports.

## Start a two-box cluster

Box 1:

```bash
cd MirrorNeuron
bash scripts/start_cluster_node.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --box 1
```

Box 2:

```bash
cd MirrorNeuron
bash scripts/start_cluster_node.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --box 2 --redis-host 192.168.4.29
```

## Inspect the cluster

From box 1:

```bash
bash scripts/cluster_cli.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29 -- inspect nodes
```

You want to see:

- `mn1@192.168.4.29`
- `mn2@192.168.4.35`

## Submit a cluster job

Small prime test:

```bash
bash mirrorneuron-blueprints/prime_sweep_scale/run_scale_test.sh \
  --workers 4 \
  --start 1000003 \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --self-ip 192.168.4.29
```

## Common cluster failure patterns

### `:nodistribution`

Usually means:
- `epmd` is not running
- port `4369` is blocked
- the BEAM node port is blocked

### Invalid challenge reply (Cookie mismatch)

Usually means:
- The `MIRROR_NEURON_COOKIE` differs between machines. 
- Ensure `export MIRROR_NEURON_COOKIE="your_shared_secret"` is identical on all physical boxes.

### Port `4000` already in use (`eaddrinuse`)

Usually means:
- Two nodes on the same box are trying to start the web API on `4000`.
- The Erlang `--bind` distribution port is clashing with the Web API.
- Use `export MIRROR_NEURON_API_PORT=4001` to change the web port.

### node name already in use

Usually means:
- a runtime node is already running on that machine
- a previous CLI node still exists with the same name

### split-brain

Redis acts as the ultimate arbiter via lease locks. Therefore, a split-brain condition is averted by design. If network partitions occur, the partition that can communicate with Redis maintains leadership and job ownership.

## Related docs

- [Reliability Guide](reliability.md)
- [Troubleshooting](troubleshooting.md)
- [Monitor Guide](monitor.md)