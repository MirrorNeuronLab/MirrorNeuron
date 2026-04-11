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
- shows bundle-scoped OpenShell policy files
- good first sandbox example

Run:

```bash
./mirror_neuron validate examples/openshell_worker_demo
./mirror_neuron run examples/openshell_worker_demo --json
```

Bundle-scoped OpenShell policy example:

```json
{
  "config": {
    "upload_path": "word_count",
    "workdir": "/sandbox/job/word_count",
    "command": ["bash", "scripts/collect_metrics.sh"],
    "policy": "policies/api-egress.yaml"
  }
}
```

The `policy` path is resolved relative to the bundle `payloads/` directory, so a bundle can carry its own OpenShell network allowlist. For example, [api-egress.yaml](../examples/openshell_worker_demo/payloads/policies/api-egress.yaml) allows selected API hosts and a fixed IP.

## 3. Divisibility monitor

Path:

- [examples/divisibility_monitor](../examples/divisibility_monitor)

Purpose:

- demonstrates a long-lived job that keeps running until manually stopped
- uses two BEAM module agents without OpenShell
- shows agent-to-agent looping with explicit messages
- keeps terminal progress in open-ended mode instead of a fake finite count
- uses `local_restart` recovery so old local demo runs are not auto-resumed

Run:

```bash
./mirror_neuron validate examples/divisibility_monitor
./mirror_neuron run examples/divisibility_monitor --no-await
```

Watch it:

```bash
./mirror_neuron monitor
```

## 4. Prime sweep scale benchmark

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

## 5. LLM codegen and review loop

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

## 6. Streaming peak detection demo

Path:

- [examples/streaming_peak_demo](../examples/streaming_peak_demo)

Purpose:

- demonstrates runtime-level streaming messages
- uses gzipped NDJSON chunks as the wire payload
- shows one agent producing a stream and another consuming it incrementally
- detects abnormal peaks and reports the largest anomaly

Key files:

- [generate_bundle.py](../examples/streaming_peak_demo/generate_bundle.py)
- [run_streaming_e2e.sh](../examples/streaming_peak_demo/run_streaming_e2e.sh)
- [summarize_result.py](../examples/streaming_peak_demo/summarize_result.py)
- [test_cluster_streaming_e2e.sh](../scripts/test_cluster_streaming_e2e.sh)

Run locally:

```bash
bash examples/streaming_peak_demo/run_streaming_e2e.sh
```

Run on cluster:

```bash
bash scripts/test_cluster_streaming_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35
```

## 7. Shared MPE crowd visualization

Path:

- [examples/mpe_simple_push_visualization](../examples/mpe_simple_push_visualization)

Purpose:

- run one shared PettingZoo MPE world with many agents in the same environment
- keep the execution lightweight with one `HostLocal` simulation worker and one visualizer
- produce a browser-viewable HTML visualization of the whole arena over time
- provide a much smaller simulation example than `ecosystem_simulation`

Key files:

- [generate_bundle.py](../examples/mpe_simple_push_visualization/generate_bundle.py)
- [run_simple_push_e2e.sh](../examples/mpe_simple_push_visualization/run_simple_push_e2e.sh)
- [summarize_result.py](../examples/mpe_simple_push_visualization/summarize_result.py)
- [Shared MPE Crowd Example](mpe_simple_push_example.md)

Run locally:

```bash
bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh
```

Open the generated HTML automatically:

```bash
bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh --open
```

## 8. Ecosystem simulation

Path:

- [examples/ecosystem_simulation](../examples/ecosystem_simulation)

Purpose:

- stress the runtime with a large stateful simulation
- model many animals competing for limited regional resources
- exercise cross-region messaging, migration, breeding, and summary ranking
- demonstrate a BEAM-native sharded world model
- randomize world resource allocation and initial DNA per run
- report the top 10 DNA profiles at the end

Key files:

- [generate_bundle.py](../examples/ecosystem_simulation/generate_bundle.py)
- [run_simulation_e2e.sh](../examples/ecosystem_simulation/run_simulation_e2e.sh)
- [summarize_result.py](../examples/ecosystem_simulation/summarize_result.py)
- [watch_ascii.exs](../examples/ecosystem_simulation/watch_ascii.exs)
- [Simulation Example Guide](simulation_example.md)

Run locally:

```bash
bash examples/ecosystem_simulation/run_simulation_e2e.sh
```

Run on cluster:

```bash
bash scripts/test_cluster_ecosystem_sim_e2e.sh \
  --box1-ip 192.168.4.29 \
  --box2-ip 192.168.4.35
```

## Choosing the right example

Use this order:

1. `research_flow`
2. `openshell_worker_demo`
3. `divisibility_monitor`
4. `prime_sweep_scale`
5. `streaming_peak_demo`
6. `mpe_simple_push_visualization`
7. `llm_codegen_review`
8. `ecosystem_simulation`

That progression moves from:

- local routing
- local sandbox execution
- long-lived module-based message loops
- scale and cluster placement
- runtime streaming and incremental consumption
- visual post-processing over one shared MPE crowd world
- richer multi-agent collaboration
- large-scale stateful simulation under cluster load
