# Quickstart

This guide gets MirrorNeuron running quickly on one machine.

## Validate a simple workflow

```bash
cd /Volumes/1TB/Personal_projects/MirrorNeuron
./mirror_neuron validate examples/research_flow
```

What this does:

- loads the job bundle folder
- validates `manifest.json`
- checks node, edge, and entrypoint structure

## Run a simple workflow

```bash
./mirror_neuron run examples/research_flow
```

Expected behavior:

- CLI banner
- progress view
- final run summary

If you need machine-readable output:

```bash
./mirror_neuron run examples/research_flow --json
```

## Inspect the cluster or local runtime

```bash
./mirror_neuron inspect nodes
```

On a single machine this usually shows one node.

## Use the terminal monitor

```bash
./mirror_neuron_monitor
```

This opens a terminal dashboard where you can:

- see jobs
- see cluster nodes
- open a job
- inspect agents, sandboxes, and recent events

## Run the OpenShell demo

```bash
./mirror_neuron validate examples/openshell_worker_demo
./mirror_neuron run examples/openshell_worker_demo --json
```

This bundle uses:

- shell code
- Python code
- an aggregator sink

## Run the LLM codegen/review example

```bash
bash examples/llm_codegen_review/run_llm_e2e.sh
```

This example performs:

1. code generation
2. review
3. code regeneration
4. repeat for 3 rounds
5. validator execution

It uses Gemini 2.5 Flash Lite by default.

## Next steps

- [CLI Guide](cli.md)
- [Examples Guide](examples.md)
- [Monitor Guide](monitor.md)
