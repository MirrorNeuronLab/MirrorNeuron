# Examples Guide

MirrorNeuron currently includes several examples that cover different parts of the runtime.

## 1. Research flow

Path:

- [examples/research_flow](../examples/research_flow)

Purpose:

- smallest useful workflow
- validates routing and aggregation
- no sandbox dependency

Run:

```bash
./mirror_neuron validate examples/research_flow
./mirror_neuron run examples/research_flow
```

## 2. OpenShell worker demo

Path:

- [examples/openshell_worker_demo](../examples/openshell_worker_demo)

Purpose:

- demonstrates shell plus Python executor payloads
- shows bundle-based payload staging
- good first sandbox example

Run:

```bash
./mirror_neuron validate examples/openshell_worker_demo
./mirror_neuron run examples/openshell_worker_demo --json
```

Helper:

```bash
bash demo/openshell_pipeline/run_demo.sh
```

## 3. Prime sweep scale benchmark

Path:

- [examples/prime_sweep_scale](../examples/prime_sweep_scale)

Purpose:

- shard work across many logical executor workers
- aggregate worker results
- stress execution scheduling and sandbox reuse

Key files:

- [generate_bundle.py](../examples/prime_sweep_scale/generate_bundle.py)
- [run_scale_test.sh](../examples/prime_sweep_scale/run_scale_test.sh)
- [summarize_result.py](../examples/prime_sweep_scale/summarize_result.py)

Run locally:

```bash
bash examples/prime_sweep_scale/run_scale_test.sh --start 1000003 --end 1001202
```

Run on cluster:

```bash
bash examples/prime_sweep_scale/run_scale_test.sh \
  --workers 4 \
  --start 1000003 \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35 \
  --self-ip 192.168.4.29
```

## 4. LLM codegen and review loop

Path:

- [examples/llm_codegen_review](../examples/llm_codegen_review)

Purpose:

- meaningful end-to-end agent collaboration
- Gemini-powered code generation and review
- three rounds of generate -> review -> regenerate
- final Python validator

Local:

```bash
bash examples/llm_codegen_review/run_llm_e2e.sh
```

Cluster:

```bash
bash scripts/test_cluster_llm_codegen_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35
```

## Choosing the right example

Use this order:

1. `research_flow`
2. `openshell_worker_demo`
3. `prime_sweep_scale`
4. `llm_codegen_review`

That progression moves from:

- local routing
- local sandbox execution
- scale and cluster placement
- richer multi-agent collaboration
