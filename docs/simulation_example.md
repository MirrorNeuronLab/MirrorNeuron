# Ecosystem Simulation Example

This example is a large-scale, BEAM-native ecosystem simulation designed to stress MirrorNeuron with many stateful entities, cross-shard messaging, and a meaningful final result.

Path:

- [mirrorneuron-blueprints/ecosystem_simulation](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation)

## What it simulates

The simulation models animals with compact DNA traits:

- `metabolism`
- `forage`
- `breed`
- `aggression`
- `move`
- `longevity`

Each run introduces randomness in:

- region resource profiles
- initial animal allocation across regions
- initial DNA distribution
- mutation during reproduction

Animals compete for limited food, age, die, reproduce, and migrate between neighboring regions. At the end, the run reports the top 10 DNA profiles by survival and lineage strength.

The `--animals` flag is the initial population for the run. It does not mean “up to” or “range.”

## Why this example is BEAM-native

This example intentionally keeps simulation state in BEAM agent state instead of sandbox files.

The architecture is:

- one `ingress` router
- one `world` module agent
- many `region_*` module agents
- one `collector` aggregator
- one `summarizer` module agent

That gives us an actor-style model:

- the world agent owns global setup
- each region agent owns a shard of the simulation state
- animals live inside their owning region state
- regions exchange migration batches by message
- the collector and summarizer produce the final report

This keeps the important BEAM properties:

- clear ownership
- local mutable state inside the owning process
- message passing between shards
- much lower coordination overhead than serializing the full world through Redis every tick

## Agent layout

### `ingress`

- built-in `router`
- starts the run by emitting `simulation_start`

### `world`

- `agent_type: "module"`
- module: `MirrorNeuron.Examples.EcosystemSimulation.WorldAgent`
- bootstraps the run
- creates randomized region profiles
- allocates initial animals across regions
- emits `region_bootstrap` to every region

### `region_*`

- `agent_type: "module"`
- module: `MirrorNeuron.Examples.EcosystemSimulation.RegionAgent`
- each region owns:
  - its animals
  - local food/resource pool
  - births/deaths
  - migration inbox
  - local history tail
- each tick a region:
  - regenerates food
  - processes local competition
  - breeds survivors with low-rate mutation
  - kills exhausted or old animals
  - sends migration batches to neighboring regions
  - schedules its next tick

### `collector`

- built-in `aggregator`
- waits for one `region_summary` from each region

### `summarizer`

- `agent_type: "module"`
- module: `MirrorNeuron.Examples.EcosystemSimulation.LeaderboardAgent`
- merges all region summaries
- computes the top 10 DNA leaderboard
- completes the job

## State model

The important design choice is that animals are not individual runtime agents.

Instead:

- each region agent holds many animals in its local state
- animals are modeled as plain entity maps
- the shard, not the entity, is the runtime state owner

This is much cheaper than spawning thousands of heavyweight workers while still preserving actor-style ownership.

Redis still stores:

- job records
- agent snapshots
- event history
- recovery metadata

But Redis is not used as the primary simulation database.

## Message flow

The core flow is:

1. `ingress` emits `simulation_start`
2. `world` emits `region_bootstrap` to all region agents
3. each region initializes its shard state and schedules `region_tick`
4. on each tick, a region may emit:
   - `migration_batch` to neighboring regions
   - another `region_tick` to itself
5. after the last tick, each region emits `region_summary`
6. `collector` aggregates all summaries
7. `summarizer` ranks the top DNA profiles and completes the job

## Local run

```bash
cd MirrorNeuron
bash mirrorneuron-blueprints/ecosystem_simulation/run_simulation_e2e.sh
```

Smaller smoke test:

```bash
bash mirrorneuron-blueprints/ecosystem_simulation/run_simulation_e2e.sh \
  --animals 120 \
  --regions 4 \
  --duration-seconds 60 \
  --tick-seconds 5
```

The local runner rebuilds `./mirror_neuron`, generates the bundle, validates it, runs the simulation, and writes a `result.json` next to the generated manifest.

Important:

- `duration-seconds` is simulated world time, not wall-clock runtime
- in the ecosystem watcher, simulated time is rendered as years (`y`)
- total ticks are calculated as `duration-seconds / tick-seconds`

For a more watchable run, use:

```bash
bash mirrorneuron-blueprints/ecosystem_simulation/run_simulation_e2e.sh \
  --animals 800 \
  --regions 8 \
  --duration-seconds 300 \
  --tick-seconds 5 \
  --watch
```

When `--watch` is enabled, the runner applies a small real wall-clock delay per tick by default so the ASCII dashboard has time to show the world evolving. You can override that with `--tick-delay-ms`.

## ASCII dashboard

There is also a terminal-only watcher for this example:

- [watch_ascii.exs](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/watch_ascii.exs)

It renders:

- job status and tick progress
- simulated time as `?y`
- per-region population and food bars
- numeric food level (`current/capacity`) and a short `up` / `down` / `flat` food trend
- a rolling DNA leaderboard
- recent events

The watcher combines two sources:

- live agent state from `inspect_agents`
- lightweight observation events emitted by region agents on every tick

That observation path makes the dashboard feel more responsive during long runs because it does not need to wait only on slower state polling.

The initial region rows are hydrated from `region_initialized` events, so the opening screen shows the real randomized starting food distribution instead of empty placeholder rows.

Example on a long-lived local runtime:

Terminal 1:

```bash
cd MirrorNeuron
./mirror_neuron server
```

Terminal 2:

```bash
python3 mirrorneuron-blueprints/ecosystem_simulation/generate_bundle.py --animals 800 --regions 8
./mirror_neuron run mirrorneuron-blueprints/ecosystem_simulation/generated/ecosystem_simulation_800_animals_8_regions_300s --json --no-await
```

Terminal 3:

```bash
mix run mirrorneuron-blueprints/ecosystem_simulation/watch_ascii.exs -- <job_id>
```

You can also inspect a completed run once:

```bash
mix run mirrorneuron-blueprints/ecosystem_simulation/watch_ascii.exs -- <job_id> --once --no-clear
```

### Reading the dashboard

- `Tick` is simulation tick progress, not wall-clock seconds
- `Sim Time` is simulated years derived from `tick * tick-seconds`
- `Food` bar is normalized against each region’s own `food_capacity`
- `LEVEL` shows `current_food/current_capacity`
- `TREND` is based on the recent region history tail
- `BOX` shows the runtime node currently associated with that region when available

## Two-box cluster run

From box 1:

```bash
cd MirrorNeuron
bash scripts/test_cluster_ecosystem_sim_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35
```

Smaller cluster smoke test:

```bash
bash scripts/test_cluster_ecosystem_sim_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --animals 240 \
  --regions 6 \
  --duration-seconds 60 \
  --tick-seconds 5 \
  --wait-timeout-seconds 240
```

The cluster harness:

- syncs the repo to box 2
- builds the runtime on both boxes
- starts both runtime nodes
- forms the cluster
- runs the ecosystem simulation through `cluster_cli.sh`
- prints the final summary
- stops the runtime nodes afterward

To keep the cluster up and watch it live:

```bash
bash scripts/test_cluster_ecosystem_sim_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --keep-cluster-up
```

Then in another terminal on box 1:

```bash
mix run mirrorneuron-blueprints/ecosystem_simulation/watch_ascii.exs -- <job_id> --box1-ip 192.168.4.29
```

## Output

The final result includes:

- simulation seed
- surviving population
- births and deaths
- migration counts
- an ASCII world population chart across the full run
- a `population_timeline` that starts at tick `0`, so the chart reflects the true initial population
- per-region resource profiles
- short region history tails
- top 10 DNA profiles

## Long-run balance

The ecosystem uses density-dependent balancing so long runs stay bounded:

- breeding chance drops as a region approaches and exceeds its carrying capacity
- higher scarcity reduces breeding further
- death pressure increases with crowding, scarcity, and age
- mutation remains low by default so successful DNA lines evolve gradually instead of thrashing
- starting food is randomized per region as a fraction of local food capacity, then changes dynamically as regions consume and regenerate resources

That keeps the simulation interesting over hundreds of ticks without letting population growth overwhelm the cluster.

That makes it useful both as:

- a performance test
- a message-heavy cluster test
- a small evolutionary simulation demo

## Files

- [generate_bundle.py](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/generate_bundle.py)
- [run_simulation_e2e.sh](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/run_simulation_e2e.sh)
- [summarize_result.py](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/summarize_result.py)
- [watch_ascii.exs](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/watch_ascii.exs)
- [world_agent.ex](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/payloads/beam_modules/world_agent.ex)
- [region_agent.ex](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/payloads/beam_modules/region_agent.ex)
- [leaderboard_agent.ex](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/payloads/beam_modules/leaderboard_agent.ex)
- [core.ex](https://github.com/MirrorNeuron/mirrorneuron-blueprints/tree/main/ecosystem_simulation/payloads/beam_modules/core.ex)
- [test_cluster_ecosystem_sim_e2e.sh](../scripts/test_cluster_ecosystem_sim_e2e.sh)
