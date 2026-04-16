# CLI Guide

MirrorNeuron currently ships two terminal tools:

- [mirror_neuron](../mn)
- `./mn monitor`

## `mirror_neuron`

### Main commands

```bash
mn standalone-start
mn cluster start --node-id <id> --bind <ip:port> [--data-dir <dir>] [--join <seeds>]
mn cluster join --node-id <id> --bind <ip:port> --seeds <seeds>
mn cluster discover --seeds <seeds>
mn cluster status
mn cluster nodes
mn cluster leave --node-id <id>
mn cluster rebalance
mn cluster elect-leader
mn cluster health
mn cluster reload --node-id <id>
mn validate <job-folder>
mn run <job-folder> [--json] [--timeout <ms>] [--no-await]
mn monitor [--json] [--running-only] [--limit <n>]
mn job list [--live]
mn job inspect <job_id>
mn agent list <job_id>
mn node list
mn events <job_id>
mn bundle reload <bundle_id>
mn bundle check <bundle_id>
mn node add <node_name>
mn node remove <node_name>
mn pause <job_id>
mn resume <job_id>
mn cancel <job_id>
mn send <job_id> <agent_id> <message.json>
```

### `standalone-start`

```bash
./mn standalone-start
```

Starts an isolated, standalone runtime server instance.

### `cluster`

```bash
./mn cluster start --node-id my-node --bind 127.0.0.1:4000
./mn cluster join --node-id my-node-2 --bind 127.0.0.1:4001 --seeds my-node@127.0.0.1
./mn cluster nodes --join my-node@127.0.0.1
```

Use the `cluster` command to start, discover, inspect, and manage the peer-to-peer distribution and membership lifecycle.

### `validate`

```bash
./mn validate mirrorneuron-blueprints/research_flow
```

Use it to verify:

- bundle structure
- manifest syntax
- node and edge relationships

### `run`

```bash
./mn run mirrorneuron-blueprints/research_flow
```

Interactive mode shows:

- banner
- job submission card
- live progress panel
- final summary

> 💡 **Important Architecture Note:**  
> When you use `mn run`, your CLI is acting as a *client* submitting a job to the cluster. The job itself runs in the background. If you press `Ctrl+C` or press `q` then `Enter` in the interactive monitor, your terminal safely detaches, but the job **keeps running**. 
> To actually stop a job, you must use `mn cancel <job_id>`.

Script mode:

```bash
./mn run mirrorneuron-blueprints/research_flow --json
```

Detached mode:

```bash
./mn run mirrorneuron-blueprints/research_flow --no-await
```

Timeout:

```bash
./mn run mirrorneuron-blueprints/research_flow --timeout 10000
```

### `inspect`

Job:

```bash
./mn job inspect <job_id>
```

Agents:

```bash
./mn agent list <job_id>
```

Nodes:

```bash
./mn node list
```

### `events`

```bash
./mn events <job_id>
```

Useful for:

- debugging message flow
- seeing lease events
- seeing sandbox completion/failure events

### `pause`, `resume`, `cancel`

```bash
./mn pause <job_id>
./mn resume <job_id>
./mn cancel <job_id>
./mn cancel # Interactive safe cancel flow
```

When you type `./mn cancel` with no `job_id`, the system will show all actively running jobs and let you choose which to safely cancel.

### `job cleanup`

```bash
./mn job cleanup
./mn job cleanup --all
```

Clears out jobs that are already in a terminal state (completed, failed, or cancelled) from the Redis datastore. Use `--all` to clear out all jobs (including ones that are actively running) and start fresh.

### `send`

```bash
./mn send <job_id> <agent_id> '{"type":"manual_result","payload":{"ok":true}}'
```

Useful for:

- manual testing
- sensor-style workflows
- operator intervention

## `mn monitor`

### Start the monitor

```bash
./mn monitor
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
./mn monitor --json
```

This is useful for:

- automation
- scripting
- future dashboards

### Running-only filter

```bash
./mn monitor --running-only
```

### Cluster mode

```bash
./mn monitor \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --self-ip 192.168.4.29
```

This creates a temporary control node that attaches to the runtime cluster.

For more details:

- [Monitor Guide](monitor.md)
- [Cluster Guide](cluster.md)
