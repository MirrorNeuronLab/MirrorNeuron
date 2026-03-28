# Cluster Guide

This guide covers MirrorNeuron in two-box dev mode and similar small clusters.

## Cluster model

MirrorNeuron cluster mode uses:

- BEAM node distribution
- `libcluster`
- `Horde`
- shared Redis metadata

Runtime nodes host:

- jobs
- agents
- lease managers
- shared job sandboxes

Control nodes are lightweight one-shot CLI nodes used for:

- submission
- inspection
- monitoring

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
bash examples/prime_sweep_scale/run_scale_test.sh \
  --workers 4 \
  --start 1000003 \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --self-ip 192.168.4.29
```

## Full cluster e2e harnesses

Prime workflow:

```bash
bash scripts/test_cluster_prime_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --start 1000003 \
  --end 1000202
```

LLM codegen/review workflow:

```bash
bash scripts/test_cluster_llm_codegen_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35
```

## Monitor a cluster

```bash
./mirror_neuron_monitor \
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

### node name already in use

Usually means:

- a runtime node is already running on that machine
- a previous CLI node still exists with the same name

### cluster formed but workers fail on one box

Usually means:

- payload bundle does not exist on the remote box at the same path
- Python/OpenShell environment differs across boxes

### only one box appears to do work

Possible causes:

- tiny jobs
- local capacity imbalance
- stale cluster membership
- control node confusion from older CLI processes

## Related docs

- [Troubleshooting](troubleshooting.md)
- [Monitor Guide](monitor.md)
