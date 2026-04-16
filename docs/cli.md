# CLI Guide

MirrorNeuron currently ships two terminal tools:

- [mirror_neuron](../mirror_neuron)
- `./mirror_neuron monitor`

## `mirror_neuron`

### Main commands

```bash
mirror_neuron standalone-start
mirror_neuron cluster start --node-id <id> --bind <ip:port> [--data-dir <dir>] [--join <seeds>]
mirror_neuron cluster join --node-id <id> --bind <ip:port> --seeds <seeds>
mirror_neuron cluster discover --seeds <seeds>
mirror_neuron cluster status
mirror_neuron cluster nodes
mirror_neuron cluster leave --node-id <id>
mirror_neuron cluster rebalance
mirror_neuron cluster elect-leader
mirror_neuron cluster health
mirror_neuron cluster reload --node-id <id>
mirror_neuron validate <job-folder>
mirror_neuron run <job-folder> [--json] [--timeout <ms>] [--no-await]
mirror_neuron monitor [--json] [--running-only] [--limit <n>]
mirror_neuron job list [--live]
mirror_neuron job inspect <job_id>
mirror_neuron agent list <job_id>
mirror_neuron node list
mirror_neuron events <job_id>
mirror_neuron bundle reload <bundle_id>
mirror_neuron bundle check <bundle_id>
mirror_neuron node add <node_name>
mirror_neuron node remove <node_name>
mirror_neuron pause <job_id>
mirror_neuron resume <job_id>
mirror_neuron cancel <job_id>
mirror_neuron send <job_id> <agent_id> <message.json>
```

### `standalone-start`

```bash
./mirror_neuron standalone-start
```

Starts an isolated, standalone runtime server instance.

### `cluster`

```bash
./mirror_neuron cluster start --node-id my-node --bind 127.0.0.1:4000
./mirror_neuron cluster join --node-id my-node-2 --bind 127.0.0.1:4001 --seeds my-node@127.0.0.1
./mirror_neuron cluster nodes --join my-node@127.0.0.1
```

Use the `cluster` command to start, discover, inspect, and manage the peer-to-peer distribution and membership lifecycle.

### `validate`

```bash
./mirror_neuron validate mirrorneuron-blueprints/research_flow
```

Use it to verify:

- bundle structure
- manifest syntax
- node and edge relationships

### `run`

```bash
./mirror_neuron run mirrorneuron-blueprints/research_flow
```

Interactive mode shows:

- banner
- job submission card
- live progress panel
- final summary

Script mode:

```bash
./mirror_neuron run mirrorneuron-blueprints/research_flow --json
```

Detached mode:

```bash
./mirror_neuron run mirrorneuron-blueprints/research_flow --no-await
```

Timeout:

```bash
./mirror_neuron run mirrorneuron-blueprints/research_flow --timeout 10000
```

### `inspect`

Job:

```bash
./mirror_neuron job inspect <job_id>
```

Agents:

```bash
./mirror_neuron agent list <job_id>
```

Nodes:

```bash
./mirror_neuron node list
```

### `events`

```bash
./mirror_neuron events <job_id>
```

Useful for:

- debugging message flow
- seeing lease events
- seeing sandbox completion/failure events

### `pause`, `resume`, `cancel`

```bash
./mirror_neuron pause <job_id>
./mirror_neuron resume <job_id>
./mirror_neuron cancel <job_id>
```

### `send`

```bash
./mirror_neuron send <job_id> <agent_id> '{"type":"manual_result","payload":{"ok":true}}'
```

Useful for:

- manual testing
- sensor-style workflows
- operator intervention

## `mirror_neuron monitor`

### Start the monitor

```bash
./mirror_neuron monitor
```

It shows:

- cluster nodes
- visible jobs
- how many boxes a job is using
- sandbox count
- last event

Open a job by:

- typing its table index
- or typing the full job id

### JSON mode

```bash
./mirror_neuron monitor --json
```

This is useful for:

- automation
- scripting
- future dashboards

### Running-only filter

```bash
./mirror_neuron monitor --running-only
```

### Cluster mode

```bash
./mirror_neuron monitor \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --self-ip 192.168.4.29
```

This creates a temporary control node that attaches to the runtime cluster.

For more details:

- [Monitor Guide](monitor.md)
- [Cluster Guide](cluster.md)
