# MirrorNeuron API

This document describes the read and control APIs that the CLI tools currently consume.

The goal is to keep these shapes stable enough for future tools such as:

- terminal monitors
- lightweight web dashboards
- automation hooks
- external operational scripts

## Public Elixir API

These functions are exposed from [MirrorNeuron](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron.ex).

### Job execution

#### `MirrorNeuron.validate_manifest(input)`

Validates a job bundle folder.

Input:

- `input :: String.t()` path to a job folder

Return:

- `{:ok, bundle}`
- `{:error, reason}`

The bundle includes:

- `root_path`
- `manifest_path`
- `payloads_path`
- `manifest`

#### `MirrorNeuron.run_manifest(input, opts \\ [])`

Submits a job bundle for execution.

Important options:

- `await: boolean`
- `timeout: integer | :infinity`
- `json: boolean`
- `job_bundle: bundle` internal/advanced path

Return:

- `{:ok, job_id}` when `await: false`
- `{:ok, job_id, job}` when `await: true`
- `{:error, reason}`

#### `MirrorNeuron.wait_for_job(job_id, timeout \\ :infinity)`

Waits for terminal status:

- `completed`
- `failed`
- `cancelled`

Return:

- `{:ok, job_map}`
- `{:error, reason}`

### Inspection

#### `MirrorNeuron.inspect_job(job_id)`

Reads the persisted job record from Redis.

Return:

- `{:ok, job_map}`
- `{:error, reason}`

Typical job fields:

```json
{
  "job_id": "prime_sweep_40_workers-...",
  "graph_id": "prime_sweep_40_workers",
  "job_name": null,
  "status": "completed",
  "submitted_at": "2026-03-28T11:00:00.000Z",
  "updated_at": "2026-03-28T11:00:12.000Z",
  "placement_policy": "local",
  "recovery_policy": "local_restart",
  "root_agent_ids": ["dispatcher"],
  "result": {},
  "manifest_ref": {
    "graph_id": "prime_sweep_40_workers",
    "manifest_version": "1.0",
    "manifest_path": "/abs/path/manifest.json",
    "job_path": "/abs/path/job-folder"
  }
}
```

#### `MirrorNeuron.inspect_agents(job_id)`

Reads persisted agent snapshots.

Return:

- `{:ok, [agent_snapshot]}`
- `{:error, reason}`

Typical agent fields:

```json
{
  "agent_id": "prime_worker_0001",
  "agent_type": "executor",
  "assigned_node": "mn1@192.168.4.183",
  "processed_messages": 1,
  "mailbox_depth": 0,
  "current_state": {
    "runs": 1,
    "last_result": {
      "sandbox_name": "mirror-neuron-job-...",
      "lease": {
        "lease_id": "...",
        "pool": "default",
        "slots": 1
      }
    }
  },
  "metadata": {
    "paused": false,
    "outbound_edges": ["aggregator"]
  }
}
```

#### `MirrorNeuron.events(job_id)`

Reads the Redis-backed append-only event list for the job.

Return:

- `{:ok, [event]}`
- `{:error, reason}`

Typical event fields:

```json
{
  "timestamp": "2026-03-28T11:00:04.000Z",
  "type": "sandbox_job_completed",
  "agent_id": "prime_worker_0001",
  "payload": {
    "sandbox_name": "mirror-neuron-job-...",
    "exit_code": 0,
    "pool": "default"
  }
}
```

#### `MirrorNeuron.inspect_nodes()`

Returns cluster node summaries with executor pool stats.

Return:

- `[%{...}]`

Typical fields:

```json
[
  {
    "name": "mn1@192.168.4.183",
    "connected_nodes": ["mn1@192.168.4.183", "mn2@192.168.4.35"],
    "self?": true,
    "scheduler_hint": "cluster_member",
    "executor_pools": {
      "default": {
        "capacity": 2,
        "available": 1,
        "in_use": 1,
        "queued": 0,
        "active": 1
      }
    }
  }
]
```

### Control

#### `MirrorNeuron.pause(job_id)`
#### `MirrorNeuron.resume(job_id)`
#### `MirrorNeuron.cancel(job_id)`
#### `MirrorNeuron.send_message(job_id, agent_id, message)`

These are the control-plane mutation APIs currently used by the main CLI.

## Monitor API

These functions are implemented in [monitor.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/monitor.ex) and are intended as the stable read model for operational tooling.

### `MirrorNeuron.list_jobs(opts \\ [])`

Returns enriched job summaries.

Supported options:

- `limit: integer`
- `include_terminal: boolean`

Return:

- `{:ok, [job_summary]}`
- `{:error, reason}`

`job_summary` includes:

- `job_id`
- `graph_id`
- `job_name`
- `status`
- `submitted_at`
- `updated_at`
- `placement_policy`
- `recovery_policy`
- `executor_count`
- `active_executors`
- `nodes`
- `sandbox_names`
- `last_event`

### `MirrorNeuron.job_details(job_id, opts \\ [])`

Returns the full monitor detail view for one job.

Supported options:

- `event_limit: integer` default `25`

Return:

- `{:ok, details}`
- `{:error, reason}`

`details` includes:

- `job`
- `summary`
- `agents`
- `sandboxes`
- `recent_events`

Each agent entry includes:

- `agent_id`
- `agent_type`
- `assigned_node`
- `status`
- `running?`
- `processed_messages`
- `mailbox_depth`
- `paused?`
- `last_error`
- `sandbox_name`
- `lease`

### `MirrorNeuron.cluster_overview(opts \\ [])`

Convenience call that combines:

- `MirrorNeuron.inspect_nodes/0`
- `MirrorNeuron.list_jobs/1`

Return:

- `{:ok, %{"nodes" => [...], "jobs" => [...]}}`
- `{:error, reason}`

## Redis persistence keys

The current monitor API is backed by these Redis structures in [redis_store.ex](/Volumes/1TB/Personal_projects/MirrorNeuron/lib/mirror_neuron/persistence/redis_store.ex).

Namespace prefix:

- `mirror_neuron` by default
- configurable through `:redis_namespace`

Key shapes:

- `mirror_neuron:jobs`
  - Redis set of known job ids
- `mirror_neuron:job:<job_id>`
  - JSON job record
- `mirror_neuron:job:<job_id>:events`
  - Redis list of JSON events
- `mirror_neuron:job:<job_id>:agents`
  - Redis set of agent ids
- `mirror_neuron:job:<job_id>:agent:<agent_id>`
  - JSON agent snapshot

Pub/Sub channel:

- `mirror_neuron:channel:events:<job_id>`

This event channel is written today but not yet consumed by the terminal monitor. It is the best candidate for future live dashboards.

## Terminal tools

### Main CLI

Built escript:

- [mirror_neuron](/Volumes/1TB/Personal_projects/MirrorNeuron/mirror_neuron)

### Monitor CLI

Wrapper command:

- [mirror_neuron_monitor](/Volumes/1TB/Personal_projects/MirrorNeuron/mirror_neuron_monitor)

It currently uses:

- `MirrorNeuron.cluster_overview/1`
- `MirrorNeuron.job_details/2`

If cluster monitoring is needed, start it with the same `MIRROR_NEURON_*` environment used by control nodes.

## Stability guidance

For future tools, prefer consuming:

1. `MirrorNeuron.list_jobs/1`
2. `MirrorNeuron.job_details/2`
3. `MirrorNeuron.cluster_overview/1`

Avoid coupling directly to raw Redis keys unless you are building low-level operational tooling.
