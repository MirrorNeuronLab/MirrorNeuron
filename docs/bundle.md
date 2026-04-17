# Job Bundle Format

In MirrorNeuron, a **Job Bundle** is the standard deployment package for a multi-agent workflow. It defines the structure of the agent graph, the initial state, and any necessary executable payloads or static data required to run the job in an isolated execution sandbox.

## Bundle Structure

A valid job bundle is a directory with the following structure:

```text
my_job_bundle/
├── manifest.json
└── payloads/
    ├── worker_script.py
    └── data.json
```

- **`manifest.json`**: The declarative workflow definition. It maps out nodes (agents), edges (message routing), and execution policies.
- **`payloads/`**: A required directory containing all external static assets, shell scripts, Python code, and data files referenced by the executor nodes. The runtime resolves any relative `source` paths in the manifest against this directory before uploading them to the OpenShell sandbox.

---

## The `manifest.json` Schema

The `manifest.json` is a JSON document that defines the execution graph.

### Top-level Fields

| Field | Type | Description |
|-------|------|-------------|
| `manifest_version` | String | **Required.** The version of the manifest format (e.g., `"1.0"`). |
| `graph_id` | String | **Required.** A unique identifier for the agent graph. |
| `job_name` | String | Optional. A human-readable name for the job. Defaults to `graph_id` if missing. |
| `daemon` | Boolean | Optional. Set to `true` for workflows intended to run until manually stopped. Defaults to `false`. |
| `metadata` | Object | Optional. Custom metadata tags for the job. |
| `entrypoints` | Array | **Required.** A list of `node_id` strings where initial inputs will be injected to start the graph. |
| `initial_inputs` | Object | Optional. A map where the keys are `node_id`s (from `entrypoints`) and values are arrays of message payloads to seed the job. |
| `nodes` | Array | **Required.** The list of agent nodes that make up the workflow. |
| `edges` | Array | **Required.** The list of message-routing edges between nodes. |
| `policies` | Object | Optional. Job-level policies like `recovery_mode`. |

### Nodes (Agents)

Each item in the `nodes` array defines an agent that will be supervised by the BEAM runtime.

| Field | Type | Description |
|-------|------|-------------|
| `node_id` | String | **Required.** Unique identifier for this node within the graph. |
| `agent_type` | String | **Required.** The core runtime primitive. Typically `"router"`, `"executor"`, `"aggregator"`, or `"sensor"`. |
| `type` | String | Optional. The behavioral template (e.g., `"map"`, `"reduce"`, `"stream"`, `"batch"`). Defaults to `"generic"`. |
| `role` | String | Optional. A human-readable tag describing the agent's domain role (e.g., `"researcher"`, `"root_coordinator"`). |
| `config` | Object | Optional. Configuration specific to the `agent_type` and `type` (e.g., `emit_type`, `pool`, `uploads`). |

### Edges (Routing)

Edges dictate how messages flow between agents after a step completes.

| Field | Type | Description |
|-------|------|-------------|
| `from_node` | String | **Required.** The `node_id` of the sending agent. |
| `to_node` | String | **Required.** The `node_id` of the receiving agent. |
| `message_type` | String | **Required.** The event or message type that triggers this edge (e.g., `"research_request"`). |

---

## The `payloads/` Directory

Because MirrorNeuron strictly separates the control plane (BEAM orchestration) from the execution plane (OpenShell sandboxes), any code executed by an `"executor"` agent must be supplied through the `payloads/` directory.

When you configure an executor node to run a script, you declare it in the `config.uploads` map. The `source` paths are evaluated relative to the `payloads/` directory:

```json
{
  "node_id": "python_worker",
  "agent_type": "executor",
  "config": {
    "uploads": [
      {
        "source": "process_data.py",
        "target": "/sandbox/process_data.py"
      }
    ],
    "command": ["python3", "/sandbox/process_data.py"]
  }
}
```

In this example, the runtime will look for `my_job_bundle/payloads/process_data.py` and mount it into the OpenShell sandbox at `/sandbox/process_data.py`.

---

## Example Bundle

Here is a simple example of a complete `manifest.json` for a Map-Reduce style workflow.

```json
{
  "manifest_version": "1.0",
  "graph_id": "document_summarizer",
  "daemon": false,
  "entrypoints": ["dispatcher"],
  "initial_inputs": {
    "dispatcher": [
      {"file": "doc1.txt"},
      {"file": "doc2.txt"}
    ]
  },
  "nodes": [
    {
      "node_id": "dispatcher",
      "agent_type": "router",
      "type": "map",
      "role": "root_coordinator",
      "config": {
        "emit_type": "summarize_request"
      }
    },
    {
      "node_id": "summarizer_worker",
      "agent_type": "executor",
      "type": "map",
      "config": {
        "pool": "default",
        "uploads": [
          {
            "source": "summarize.py",
            "target": "/app/summarize.py"
          }
        ],
        "command": ["python3", "/app/summarize.py"]
      }
    },
    {
      "node_id": "result_collector",
      "agent_type": "aggregator",
      "type": "reduce",
      "config": {
        "complete_on_message": true
      }
    }
  ],
  "edges": [
    {
      "from_node": "dispatcher",
      "to_node": "summarizer_worker",
      "message_type": "summarize_request"
    },
    {
      "from_node": "summarizer_worker",
      "to_node": "result_collector",
      "message_type": "summarize_request"
    }
  ],
  "policies": {
    "recovery_mode": "local_restart"
  }
}
```

## Loading and Running

You can validate and run a job bundle using the MirrorNeuron CLI:

```bash
# Validate the bundle structure and manifest constraints
./mn validate path/to/my_job_bundle

# Execute the bundle in the cluster
./mn run path/to/my_job_bundle
```

Via the API (HTTP POST to `/api/v1/jobs`), the exact same `manifest.json` shape is accepted, with the payloads assumed to either already exist locally or omitted in pure-router workflows.
