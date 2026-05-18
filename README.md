# MirrorNeuron Core

MirrorNeuron Core is an Elixir/OTP runtime for durable, message-driven AI workflows. It runs workflow graphs, stores job state, exposes gRPC services, and supports local or clustered execution.

<!-- start-badges -->
[![License](https://img.shields.io/badge/License-MIT-blue)](https://github.com/MirrorNeuronLab/MirrorNeuron/blob/main/LICENSE)
[![Security Policy](https://img.shields.io/badge/Security-Report%20a%20Vulnerability-red)](https://github.com/MirrorNeuronLab/MirrorNeuron/security/policy)
[![Project Status](https://img.shields.io/badge/status-alpha-orange)](https://github.com/MirrorNeuronLab/mn-docs)
[![Docs](https://img.shields.io/badge/Docs-mn--docs-blue)](https://github.com/MirrorNeuronLab/mn-docs)
<!-- end-badges -->

> [!IMPORTANT]
> MirrorNeuron is in alpha. APIs, manifests, release artifacts, and ecosystem components may change between releases.

## Contents

- [Features](#features)
- [Demo](#demo)
- [Tech Stack](#tech-stack)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [API](#api)
- [Project Structure](#project-structure)
- [Testing](#testing)
- [Deployment and Releases](#deployment-and-releases)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Code of Conduct](#code-of-conduct)
- [Security](#security)
- [Acknowledgments](#acknowledgments)
- [License](#license)

## Features

| Feature | Status | Notes |
|---|---:|---|
| Workflow manifest validation | Available | Validates graph structure and supported runtime primitives. |
| Message-driven execution | Available | Routes workflow messages between runtime nodes and agents. |
| Built-in runtime primitives | Available | Includes `router`, `executor`, `aggregator`, `sensor`, and `module`. |
| Durable job state | Available | Persists job metadata, events, agents, and terminal state through Redis. |
| Runtime monitoring | Available | Lists jobs, job details, cluster overview, metrics, and dead letters. |
| Cluster coordination | Available | Uses Erlang distribution plus `libcluster` and Horde. |
| Redis high availability helpers | Available | Includes scripts and config for Redis Sentinel development workflows. |
| gRPC services | Available | Job, cluster, and observability protobuf services are included. |
| REST API, CLI, Web UI, SDK | External components | Provided by separate ecosystem repositories. |

## Demo

Screenshots, GIFs, and short workflow recordings should be added here.

Suggested demo assets:

- A short terminal recording of `mn run` or `mn blueprint run`.
- A Web UI screenshot showing a running job graph.
- A log excerpt showing workflow events and job completion.

## Tech Stack

| Area | Technology |
|---|---|
| Runtime | Elixir `~> 1.16`, OTP |
| Application packaging | `mix release` |
| Storage | Redis via `redix` |
| Clustering | Erlang distribution, `libcluster`, Horde |
| Serialization | JSON via `jason`, protobuf via `protobuf` |
| RPC | gRPC via `grpc` |
| Tests | ExUnit |
| Release channel | GitHub Releases with platform-specific OTP tarballs |

## Prerequisites

For local development:

- Elixir `~> 1.16`
- Erlang/OTP compatible with the project and CI configuration
- Redis `7` or Docker for running Redis locally
- Bash for helper scripts

For installed runtime usage:

- Docker, when using the `mn-deploy` released-package installer
- Redis, either local or containerized
- Matching OTP release asset for the target OS and CPU architecture

## Installation

### Recommended Install

Use the deployment repository installer when installing MirrorNeuron as a user-facing system:

```bash
curl -fsSL https://mirrorneuron.io/install.sh | bash
```

For the released-package installer, use `mn-deploy/install_new.sh` from the deployment repository:

```bash
git clone https://github.com/MirrorNeuronLab/mn-deploy.git
cd mn-deploy
./install_new.sh
```

That installer uses released packages instead of source checkouts:

- Core runtime from GitHub Release OTP tarballs
- Python CLI/API/SDK packages from PyPI
- Web UI package from npm

### Local Development Setup

Clone the core repository and install dependencies:

```bash
git clone https://github.com/MirrorNeuronLab/MirrorNeuron.git
cd MirrorNeuron
mix deps.get
```

Start Redis locally or with Docker:

```bash
docker run --rm --name mirror-neuron-redis -p 6379:6379 redis:7
```

Run the runtime in development mode:

```bash
mix run --no-halt
```

Build a local OTP release:

```bash
MIX_PROJECT_VERSION=1.0.0 MIX_ENV=prod mix release --overwrite
_build/prod/rel/mirror_neuron/bin/mirror_neuron start
```

## Configuration

Runtime configuration is read from environment variables in `config/runtime.exs`.

### Core Settings

| Variable | Default | Description |
|---|---|---|
| `MN_ENV` | `dev` | Runtime environment. Must be `dev`, `test`, or `prod`. |
| `MN_COOKIE` | `mirrorneuron` | Erlang distribution cookie. |
| `MN_NODE_NAME` | Not set by config | Erlang node name used by release/cluster scripts. |
| `MN_CLUSTER_NODES` | Empty | Comma-separated Erlang node names for cluster discovery. |
| `MN_RELIABILITY_STRATEGY` | `auto` | Conservative runtime strategy resolver for new jobs. |
| `MN_CLUSTER_HEALTH_STABLE_MS` | `10000` | Debounce window before a healthy connected cluster is trusted for multi-node recovery. |
| `MN_RELIABILITY_OBSERVER_INTERVAL_MS` | `5000` | Interval for publishing reliability mode and job reliability notices. |
| `MN_NODE_RECONNECT_ATTEMPTS` | `3` | Runtime node reconnect attempts before jobs are paused for manual restart. |
| `MN_NODE_RECONNECT_BACKOFF_MS` | `1000` | Initial runtime node reconnect backoff; each retry doubles the previous delay. |
| `MN_EXECUTION_PROFILES_JSON` | `{}` | JSON object defining profiled OpenShell executors, including image, pool, GPU need, policy, warmup command, and concurrency hints. |
| `MN_NODE_EXECUTION_PROFILES` | Empty | Comma-separated execution profiles this runtime node may advertise after warmup. Empty means the node advertises no profiled executors. |
| `MN_NODE_CAPABILITIES` | Empty | Comma-separated runtime capabilities such as `video-codec:h264` or `ffmpeg`. |
| `MN_NODE_GPU` | Auto-detected | Optional override for whether this runtime node advertises GPU capacity. |
| `MN_CORE_HOST` | `localhost` | Host/IP used by the gRPC listener. |
| `MN_GRPC_PORT` | `50051` | gRPC port. |
| `MN_GRPC_OPERATOR_TOKEN` | Empty | Required bearer or `x-mirror-neuron-operator-token` metadata token for gRPC operator control RPCs such as pause and resume. |
| `MN_API_ENABLED` | `true` | Enables API-related runtime config. |
| `MN_API_PORT` | `4000` | Core API config port. The separate `mn-api` package uses its own defaults. |
| `MN_TEMP_DIR` | `/tmp/mirror_neuron` | Temporary runtime directory. |
| `MN_OPENSHELL_BIN` | `openshell` | OpenShell executable path or command name. |

### Redis Settings

| Variable | Default | Description |
|---|---|---|
| `MN_REDIS_HOST` | `localhost` | Redis host used to build the default Redis URL. |
| `MN_REDIS_URL` | `redis://localhost:6379/0` | Redis connection URL. |
| `MN_REDIS_NAMESPACE` | `mirror_neuron` | Prefix/namespace for persisted runtime data. |
| `MN_REDIS_DB` | `0` | Redis database number. |
| `MN_REDIS_USERNAME` | Empty | Redis username. |
| `MN_REDIS_PASSWORD` | Empty | Redis password. |
| `MN_REDIS_HA_MODE` | `single` | Redis mode, currently `single` or Sentinel-related configuration. |
| `MN_REDIS_SENTINELS` | Empty | Comma-separated Sentinel endpoints. |
| `MN_REDIS_SENTINEL_MASTER` | `mirror-neuron` | Sentinel master name. |
| `MN_REDIS_SENTINEL_HOST_MAP` | Empty | Optional host mapping used when resolving Sentinel primary hosts. |
| `MN_REDIS_SENTINEL_USERNAME` | Empty | Sentinel username. |
| `MN_REDIS_SENTINEL_PASSWORD` | Empty | Sentinel password. |
| `MN_REDIS_WAIT_REPLICAS` | `0` | Redis write durability wait replica count. |
| `MN_REDIS_WAIT_TIMEOUT_MS` | `100` | Redis wait timeout in milliseconds. |
| `MN_REDIS_RECONNECT_ATTEMPTS` | `10` | Redis reconnect attempt count. |
| `MN_REDIS_RECONNECT_BACKOFF_MS` | `250` | Initial Redis reconnect backoff. |
| `MN_REDIS_RECONNECT_MAX_BACKOFF_MS` | `2000` | Maximum Redis reconnect backoff. |

### Resource Admission

| Variable | Default | Description |
|---|---|---|
| `MN_RESOURCE_ADMISSION_ENABLED` | `true` | Enables local resource checks before accepting work. |
| `MN_MAX_CPU_LOAD_RATIO` | See source defaults | Maximum allowed CPU load ratio. |
| `MN_MAX_MEMORY_USED_RATIO` | See source defaults | Maximum allowed memory usage ratio. |
| `MN_MAX_GPU_UTILIZATION_RATIO` | See source defaults | Maximum allowed GPU utilization ratio. |
| `MN_MAX_GPU_MEMORY_USED_RATIO` | See source defaults | Maximum allowed GPU memory usage ratio. |

Some resource-admission defaults are defined outside `runtime.exs`; check `lib/mirror_neuron/config.ex` and `lib/mirror_neuron/resource_admission.ex` before changing production thresholds.

## Usage

### Start the Core Runtime

```bash
mix run --no-halt
```

With explicit Redis and gRPC settings:

```bash
MN_REDIS_URL=redis://localhost:6379/0 \
MN_GRPC_PORT=50051 \
mix run --no-halt
```

### Validate a Manifest from Elixir

```elixir
MirrorNeuron.validate_manifest("path/to/manifest.json")
```

### Run a Manifest from Elixir

```elixir
MirrorNeuron.run_manifest("path/to/manifest.json")
```

### Adaptive Runtime Reliability

Manifests may set `"recovery_mode": "auto"` or omit `recovery_mode`. For new jobs, the runtime resolves the requested policy into an effective policy based on observed cluster health:

- Single node or uncertain/flapping cluster: `local_restart`
- Healthy multi-node cluster with a durable bundle and eligible placement: `cluster_recover`
- Explicit `manual_recover`: remains manual
- Explicit `cluster_recover` on an unsafe single-node cluster: starts degraded as `local_restart`

The runtime persists both `requested_recovery_policy` and effective `recovery_policy`, plus a compact `reliability` map for observability. Running job policies are not rewritten when cluster health changes; reliability events are emitted instead.

### Profiled OpenShell Agents

Dependency-heavy agents should reference an execution profile instead of installing native packages during each run. Configure the profile on runtime nodes, then reference it from the sandbox worker config:

```bash
MN_EXECUTION_PROFILES_JSON='{"opencv-video-guardian":{"image":"registry.local/business_facility_safety_video_guardian:2026-05","pool":"opencv_gpu","pool_slots":1,"gpu":true,"required_capabilities":["video-codec:h264"],"policy":"policies/video-egress.yaml","reuse_shared_sandbox":true,"persistent_workspace":true,"warmup_command":"python -c \"import cv2\""}}' \
MN_NODE_EXECUTION_PROFILES=opencv-video-guardian \
MN_NODE_CAPABILITIES=video-codec:h264,ffmpeg \
mix run --no-halt
```

```json
{
  "node_id": "video_guardian",
  "agent_type": "sandbox_worker",
  "config": {
    "execution_profile": "opencv-video-guardian"
  }
}
```

The BEAM runtime keeps orchestration, leases, placement, reconnect, and manual recovery. OpenCV, ffmpeg, model runtimes, and similar heavy dependencies stay in the profile image or a prewarmed node cache.

### Inspect Jobs and Events

```elixir
MirrorNeuron.list_jobs()
MirrorNeuron.inspect_job("job-id")
MirrorNeuron.inspect_agents("job-id")
MirrorNeuron.events("job-id")
```

### Pause, Resume, or Cancel a Job

```elixir
MirrorNeuron.pause("job-id")
MirrorNeuron.resume("job-id")
MirrorNeuron.cancel("job-id")
```

### Cluster Helpers

Development and smoke-test scripts are available under `scripts/`.

```bash
bash scripts/cluster_cli.sh --help
bash scripts/redis_ha.sh --help
bash scripts/test_redis_sentinel_ha.sh --help
```

## API

MirrorNeuron Core includes protobuf definitions and generated Elixir modules for:

- `proto/job.proto`
- `proto/cluster.proto`
- `proto/observability.proto`

Generated modules live under `lib/mirror_neuron_grpc/`.

The separate REST API package is maintained in [`mn-api`](https://github.com/MirrorNeuronLab/mn-api). The Python SDK is maintained in [`mn-python-sdk`](https://github.com/MirrorNeuronLab/mn-python-sdk).

## Project Structure

```text
.
├── config/                  # Mix and runtime configuration
├── lib/
│   ├── mirror_neuron/       # Core runtime modules
│   └── mirror_neuron_grpc/  # Generated gRPC/protobuf modules
├── proto/                   # gRPC protobuf definitions
├── scripts/                 # Local, cluster, Redis, and release helper scripts
├── tests/                   # ExUnit tests and script-based regression checks
├── mix.exs                  # Mix project definition
├── mix.lock                 # Locked dependencies
├── RELEASE.md              # Release policy and tag workflow
└── LICENSE                 # MIT license
```

## Testing

Install dependencies:

```bash
mix deps.get
```

Check formatting:

```bash
mix format --check-formatted
```

Run tests:

```bash
mix test
```

Compile with warnings as errors:

```bash
mix compile --warnings-as-errors
```

Run a local production release build:

```bash
MIX_PROJECT_VERSION=1.2.3 MIX_ENV=prod mix release --overwrite
```

Run shell syntax checks:

```bash
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find scripts -name '*.sh' -print0)
```

## Deployment and Releases

MirrorNeuron Core is released from Git tags. Tags must use SemVer with a leading `v`, for example:

- `v1.0.1`
- `v1.1.0`
- `v2.0.0`
- `v1.0.1-rc.1`

The release workflow builds platform-specific OTP tarballs:

- `MirrorNeuron-vX.Y.Z-darwin-arm64-otp-release.tar.gz`
- `MirrorNeuron-vX.Y.Z-linux-x64-otp-release.tar.gz`
- `MirrorNeuron-vX.Y.Z-linux-arm64-otp-release.tar.gz`
- `SHA256SUMS.txt`

Create a stable release:

```bash
git checkout main
git pull
mix deps.get
mix format --check-formatted
mix test
git tag v1.0.1
git push origin v1.0.1
```

See [RELEASE.md](RELEASE.md) for the full release process.

## Troubleshooting

| Problem | Check |
|---|---|
| Runtime cannot connect to Redis | Confirm Redis is running and `MN_REDIS_URL` points to the correct host, port, and database. |
| gRPC port is already in use | Change `MN_GRPC_PORT` or stop the process using port `50051`. |
| Cluster nodes do not join | Verify `MN_NODE_NAME`, `MN_CLUSTER_NODES`, `MN_COOKIE`, EPMD connectivity, and Erlang distribution ports. |
| Resource admission rejects jobs | Check `MN_RESOURCE_ADMISSION_ENABLED` and resource threshold variables. |
| Redis Sentinel failover is not resolving | Verify `MN_REDIS_SENTINELS`, `MN_REDIS_SENTINEL_MASTER`, credentials, and optional host mapping. |
| OTP release fails after extraction | Make sure the release asset matches the target OS and CPU architecture. |

## Roadmap

Current roadmap items should be tracked in issues or the documentation repository. Useful future additions to this README include:

- A maintained compatibility matrix for OS, CPU architecture, Elixir, and OTP versions.
- A manifest schema reference.
- A complete gRPC API reference.
- Production deployment examples.
- Screenshots or demos for CLI and Web UI workflows.

## Ecosystem

| Component | Repository |
|---|---|
| Core runtime | <https://github.com/MirrorNeuronLab/MirrorNeuron> |
| REST API | <https://github.com/MirrorNeuronLab/mn-api> |
| CLI | <https://github.com/MirrorNeuronLab/mn-cli> |
| Web UI | <https://github.com/MirrorNeuronLab/mn-web-ui> |
| Python SDK | <https://github.com/MirrorNeuronLab/mn-python-sdk> |
| Deployment tooling | <https://github.com/MirrorNeuronLab/mn-deploy> |
| System tests | <https://github.com/MirrorNeuronLab/mn-system-tests> |
| Blueprints | <https://github.com/MirrorNeuronLab/mirrorneuron-blueprints> |
| Documentation | <https://github.com/MirrorNeuronLab/mn-docs> |

## Contributing

Contributions are welcome. Before opening a pull request:

1. Run formatting and tests.
2. Keep changes scoped.
3. Add or update tests for behavior changes.
4. Update documentation when configuration, commands, or release behavior changes.

References:

- [Contributing guide](https://github.com/MirrorNeuronLab/mn-docs/blob/main/contributing.md)
- [Testing guide](https://github.com/MirrorNeuronLab/mn-docs/blob/main/testing.md)
- [Documentation style guide](https://github.com/MirrorNeuronLab/mn-docs/blob/main/documentation-style.md)

## Code of Conduct

A project-specific code of conduct is not currently included in this repository. Add one here when the project adopts a formal community policy.

## Security

Do not disclose vulnerabilities in public issues.

- Security model: <https://github.com/MirrorNeuronLab/mn-docs/blob/main/security.md>
- Report a vulnerability: <https://github.com/MirrorNeuronLab/MirrorNeuron/security>

## Acknowledgments

MirrorNeuron Core uses the Elixir/OTP ecosystem, Redis, gRPC, protobuf, Horde, and libcluster. See `mix.exs` and `mix.lock` for the current dependency list.

## License

MirrorNeuron Core is licensed under the MIT License. See [LICENSE](LICENSE).
