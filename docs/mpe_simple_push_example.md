# Shared MPE Crowd Visualization Example

This example now runs one shared PettingZoo MPE world instead of many separate rollouts.

Path:

- [examples/mpe_simple_push_visualization](../examples/mpe_simple_push_visualization)

## What changed

The old version sampled many independent `simple_push` runs and picked representative rollouts.

The new version does not rank or pick a best agent at all. Every agent coexists in one environment and the UI shows that one crowded world over time.

## Environment choice

The original `simple_push` environment only contains:

- one good agent
- one adversary

So it cannot support a single shared world with 100 coexisting agents.

This example now uses `simple_tag`, which supports configurable counts of:

- good agents
- adversaries
- obstacles

That makes it a much better fit for the "everyone in one env, pushing each other around" behavior.

## Default setup

By default the example runs one world with:

- `25` good agents
- `75` adversaries
- `8` obstacles
- `60` cycles

That gives a shared environment with `100` total agents.

## Graph shape

The runtime graph is:

- `ingress`
  - built-in `router`
  - emits `simulation_start`
- `shared_world`
  - built-in `executor`
  - runs one PettingZoo `simple_tag` world on `HostLocal`
  - records all agent positions and collision metrics across time
- `collector`
  - built-in `aggregator`
  - collects the one world result into reduce-friendly input
- `visualizer`
  - built-in `executor`
  - builds the final HTML page
  - completes the job

## UI behavior

The HTML no longer has:

- rollout selection
- best-run ranking
- representative-rollout shortcuts

Instead it shows:

- one shared arena with all agents rendered together
- a cycle scrubber and play/pause controls
- current agent-agent collisions
- obstacle contacts
- team centroids
- a collision timeline
- whole-run team summaries

## Local run

```bash
cd MirrorNeuron
bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh
```

Open the generated HTML automatically:

```bash
bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh --open
```

Smaller custom crowd:

```bash
bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh \
  --good-agents 12 \
  --adversaries 36 \
  --obstacles 5 \
  --max-cycles 40
```

Dry-run bundle generation:

```bash
bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh --dry-run
```

## Python environment

This example still uses `uv` to provision a local Python `3.12` virtual environment under:

- `examples/mpe_simple_push_visualization/.venv`

The runner installs:

- `pettingzoo[mpe]`

## Output files

After a successful run, the generated bundle directory contains:

- `manifest.json`
- `result.json`
- `mpe_crowd_summary.json`
- `mpe_crowd_visualization.html`

The HTML file is the main artifact to open in a browser.

## Behavior

The default control mode is `swarm`:

- adversaries chase nearby good agents
- good agents flee pressure
- both teams repel close neighbors
- obstacles create crowding and contact zones

You can switch to random actions with:

```bash
bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh \
  --policy-mode random
```

## Key files

- [generate_bundle.py](../examples/mpe_simple_push_visualization/generate_bundle.py)
- [run_simple_push_e2e.sh](../examples/mpe_simple_push_visualization/run_simple_push_e2e.sh)
- [summarize_result.py](../examples/mpe_simple_push_visualization/summarize_result.py)
- [run_shared_world.py](../examples/mpe_simple_push_visualization/payloads/world_worker/scripts/run_shared_world.py)
- [build_shared_world_visualization.py](../examples/mpe_simple_push_visualization/payloads/visualizer/scripts/build_shared_world_visualization.py)
