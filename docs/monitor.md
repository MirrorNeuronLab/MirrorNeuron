# Monitor Guide

MirrorNeuron includes a terminal monitor designed to be the CLI equivalent of a lightweight web operations view.

Tool:

- `./mirror_neuron monitor`

## What it shows

At the top level:

- cluster nodes
- executor pool usage
- visible jobs
- how many boxes each job is using
- sandbox count per job
- last significant event

At the job detail level:

- job summary
- runtime footprint
- sandboxes
- agents
- recent events

## Local usage

```bash
cd MirrorNeuron
./mirror_neuron monitor
```

Controls:

- type a row number to open a job
- type a full job id to open it directly
- `r` to refresh
- `b` to go back
- `q` to quit

## JSON mode

```bash
./mirror_neuron monitor --json
```

This uses the monitor API from [monitor.ex](../lib/mirror_neuron/monitor.ex).

## Cluster usage

```bash
./mirror_neuron monitor \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --self-ip 192.168.4.29
```

Useful options:

- `--seed-ip <ip>`
- `--redis-host <host>`
- `--redis-port <port>`
- `--cookie <cookie>`
- `--cli-port <port>`

## What the monitor means

### Boxes

In the overview, `boxes` means how many runtime nodes are currently visible in a job’s agent snapshots.

### Sandboxes

The sandbox count comes from:

- executor snapshots
- sandbox-related events

For short executor jobs, this gives you a practical operational view without requiring direct OpenShell inspection.

### Status values

Typical job statuses:

- `pending`
- `running`
- `completed`
- `failed`
- `cancelled`

Typical agent statuses:

- `ready`
- `busy`
- `queued`
- `running`
- `completed`
- `error`
- `paused`

## When to use the monitor vs the main CLI

Use `mirror_neuron` when you want to:

- submit jobs
- inspect one job directly
- send control commands

Use `mirror_neuron monitor` when you want to:

- see the whole platform
- identify active jobs quickly
- inspect sandboxes and agent placement
- get a terminal “ops” view

## Related docs

- [CLI Guide](cli.md)
- [API Reference](api.md)
- [Troubleshooting](troubleshooting.md)
