# MirrorNeuron Python SDK

The MirrorNeuron Python SDK allows you to author workflows directly in Python using a Temporal-like annotation style, and provides a unified CLI and API experience.

## Architecture

1. **`mn-python-sdk`**: The core Python package containing the `Client` logic and gRPC stubs. It also exposes annotations like `@workflow.defn` and `@agent.defn`.
2. **`mn-cli`**: A Typer-based CLI tool to submit, monitor, and manage jobs.
3. **`mn-api`**: A FastAPI-based REST server that uses `mn-python-sdk` to expose MirrorNeuron to HTTP clients.
4. **Core Service (Elixir)**: The BEAM runtime that runs the gRPC server and handles true execution.

## Getting Started

When you run `install.sh`, it will install the core service, the Python virtual environment, and the `mn-cli` tool.

### Defining Workflows

Instead of writing `manifest.json` files by hand, use Python!

```python
from mn_sdk import agent, workflow

@agent.defn(type="map")
def process_data(data):
    return data.upper()

@workflow.defn(name="MyDataFlow")
class MyDataFlow:
    @workflow.run
    def execute(self):
        # Implementation to be defined - currently acts as a placeholder 
        # to generate manifest definitions automatically
        pass
```

### Using the Client Programmatically

```python
from mn_sdk import Client

client = Client(target="localhost:50051")

manifest_json = '{"manifest_version": "1.0", ...}'
job_id = client.submit_job(manifest_json, payloads={})
print(f"Submitted {job_id}")

print(client.get_job(job_id))
```

### Using the CLI (`mn-cli`)

The CLI uses the SDK client under the hood.

```bash
mn submit ./my_manifest.json
mn status <job_id>
mn list
mn monitor <job_id>
```

### Using the API (`mn-api`)

The API exposes the same capabilities via REST on port 4000.

```bash
mn-api
```
