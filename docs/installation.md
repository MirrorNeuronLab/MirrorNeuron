# Installation

This guide covers the default local setup used for MirrorNeuron development and testing.

## Requirements

MirrorNeuron currently expects:

- macOS or Linux
- Elixir and Erlang
- Redis
- Docker
- OpenShell

For LLM-based examples, you also need:

- a Gemini API key available in the environment on the machine running the job

## 1. Install Elixir and Erlang

On macOS with Homebrew:

```bash
brew install elixir
elixir --version
mix --version
```

## 2. Start Redis

The simplest local path is Docker:

```bash
docker rm -f mirror-neuron-redis 2>/dev/null || true
docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7
docker exec mirror-neuron-redis redis-cli ping
```

Expected result:

```text
PONG
```

## 3. Install OpenShell

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
~/.local/bin/openshell --version
```

If `openshell` is not on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Or point MirrorNeuron directly to the binary:

```bash
export MIRROR_NEURON_OPENSHELL_BIN="$HOME/.local/bin/openshell"
```

## 4. Start the OpenShell gateway

```bash
openshell gateway start
openshell status
```

You want `Status: Connected`.

## 5. Fetch dependencies and build

```bash
cd MirrorNeuron
mix deps.get
mix test
mix escript.build
```

This builds the main CLI entry:

- [mirror_neuron](../mirror_neuron)

Monitoring is now a subcommand:

- `./mirror_neuron monitor`

## 6. Recommended local environment

These are the most commonly used environment variables:

```bash
export MIRROR_NEURON_REDIS_URL="redis://127.0.0.1:6379/0"
export MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY="4"
export MIRROR_NEURON_COOKIE="mirrorneuron"
```

Optional:

```bash
export GEMINI_API_KEY="..."
```

## 7. Smoke test

```bash
./mirror_neuron validate examples/research_flow
./mirror_neuron run examples/research_flow
./mirror_neuron monitor --json | head -n 20
```

## Cluster-specific prerequisites

For two-box or larger clusters, see:

- [Cluster Guide](cluster.md)

## Common install issues

If setup does not work as expected, start with:

- [Troubleshooting](troubleshooting.md)
