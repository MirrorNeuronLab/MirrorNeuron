# CLI Guide

MirrorNeuron currently ships two terminal tools:

- [mirror_neuron](../mirror_neuron)
- [mirror_neuron_monitor](../mirror_neuron_monitor)

## `mirror_neuron`

### Main commands

```bash
mirror_neuron server
mirror_neuron validate <job-folder>
mirror_neuron run <job-folder> [--json] [--timeout <ms>] [--no-await]
mirror_neuron inspect job <job_id>
mirror_neuron inspect agents <job_id>
mirror_neuron inspect nodes
mirror_neuron events <job_id>
mirror_neuron pause <job_id>
mirror_neuron resume <job_id>
mirror_neuron cancel <job_id>
mirror_neuron send <job_id> <agent_id> <message.json>
```

### `validate`

```bash
./mirror_neuron validate examples/research_flow
```

Use it to verify:

- bundle structure
- manifest syntax
- node and edge relationships

### `run`

```bash
./mirror_neuron run examples/research_flow
```

Interactive mode shows:

- banner
- job submission card
- live progress panel
- final summary

Script mode:

```bash
./mirror_neuron run examples/research_flow --json
```

Detached mode:

```bash
./mirror_neuron run examples/research_flow --no-await
```

Timeout:

```bash
./mirror_neuron run examples/research_flow --timeout 10000
```

### `inspect`

Job:

```bash
./mirror_neuron inspect job <job_id>
```

Agents:

```bash
./mirror_neuron inspect agents <job_id>
```

Nodes:

```bash
./mirror_neuron inspect nodes
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

## `mirror_neuron_monitor`

### Start the monitor

```bash
./mirror_neuron_monitor
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
./mirror_neuron_monitor --json
```

This is useful for:

- automation
- scripting
- future dashboards

### Running-only filter

```bash
./mirror_neuron_monitor --running-only
```

### Cluster mode

```bash
./mirror_neuron_monitor \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --self-ip 192.168.4.29
```

This creates a temporary control node that attaches to the runtime cluster.

For more details:

- [Monitor Guide](monitor.md)
- [Cluster Guide](cluster.md)
