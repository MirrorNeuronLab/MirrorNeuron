# Run resource allocation

Core admits work on the durable Job owner through an atomic, fenced ledger shared
by GUI, CLI, schedules and native model requests. `CheckRunAdmission` is read-only;
start and retry reserve before persisting an execution. Busy `start_now` requests
return `accepted: false` without creating a failed run. `enqueue_if_busy` accepts
compatible work into the durable queue. Permanent incompatibilities are rejected.

## Peak budgets

Missing profiles preserve whole-PC exclusivity. Opt in through executable
`policies.resource_allocation` (canonical blueprints: `execution.json.policies`):

```json
{
  "mode": "shared", "cpu_cores": 2, "memory_mb": 4096, "disk_mb": 1024,
  "devices": [{
    "vendor": "nvidia", "driver": "cuda", "count": 1,
    "min_memory_mb": 49152,
    "sharing": "shared", "reservation_memory_mb": 16384
  }]
}
```

The GPU minimum describes compatible hardware; the reservation describes the
run's peak use on it. Requests can constrain device IDs, GPU model names, API
versions and capabilities. `sharing: exclusive` reserves a whole selected GPU;
CPU work can use the remaining PC capacity. `mode: exclusive_node` reserves the PC.
Shared budgets cover declared worker CPU/RAM/disk/GPU needs. Include concurrent
workers, weights, contexts/KV caches and scratch memory. These are scheduling
budgets, not hardware isolation. Measure the configured workload and revise its
budget when models, context limits or concurrency change.

Smallest compatible GPUs are selected first. Shared GPUs retain the larger of
512 MiB and 10% headroom. Unified-memory GPU reservations also consume host RAM.
Stale native telemetry cannot authorize a start. Unattributed live use is charged
conservatively together with pending reservations. Shared weights are discounted
only with a matching native resident-engine attestation covering model, engine
and context settings. Attestation currently requires one physical GPU; multi-GPU
hosts retain full weight charges. Docker workers bind reserved CUDA device IDs;
agent selections are translated into the restricted container's ordinal space.
Running workers cannot be reassigned. Shared managed-model requests must fit the
run's reserved memory and single physical GPU. Multi-GPU engine binding is not
attested, so those managed-model requests require an exclusive profile.

Ports and overlapping writable host volumes remain exclusive. Shared profiles
currently require explicit ports. Prepared workers and model services must honor
the profile's device and concurrency contract.

## Queueing and reclamation

Manual starts require an explicit queue choice; schedules enqueue automatically.
After three bypasses, backfill protects the older request's best-fit resource
vector while allowing work that fits residual capacity. Claims and native
inference leases are scoped to run identity and reservation generation. Paused
runs retain reservations; stop/cancel work to return that capacity.

Completion stops owned processes, sandboxes and prepared workers, drains requests,
and releases model references. A shared model remains resident until its last
owner finishes. Stop/unload failures retain `cleanup_pending` reservations for
reconciliation. Committed claims are never freed merely because a run record is
missing, a timeout elapsed, or a PC went offline. A never-dispatched claim can be
retired under its fenced start gate. Lost native release replies have durable
completion receipts; unknown requests remain reserved until completion is proven.

Reclamation frees CPU, RAM/GPU budgets, port/folder locks and request leases.
Installed model files, reusable images, reports and durable Job data are retained;
free-disk telemetry continues to charge their physical storage.

## Moving idle Jobs

`RelocateJob` transfers an idle Job and data between federated PCs. Runs must be
terminal, cleanup finished, schedules paused and storage portable. The source
freezes starts/configuration and stops its response service. The destination
prepares an inactive definition from a streamed, checksum-verified backup. Core
attests user data and evidence independently of rewritten executable paths. A
verified staged destination permits source ownership commit; verified source
commit permits destination activation. The old owner redirects Job requests.
Historical runs, events, artifacts and paused schedules are copied without
replaying execution or old dispatches. Historical runs remain separate from the
moved service's new attached execution.

Retries resume the durable transfer. Interrupted imports finish from saved
evidence. Committed transfers retry activation and source resource cleanup in a
separate reconciler. Before commit, `mn job relocate JOB --node NODE --abort`
restores source availability; after commit, retry finishes destination activation.
Source data remains as a recovery copy. Existing destination Job IDs are never
silently overwritten.

The additive RPCs and fields retain interface version 1. Native owners must
advertise `resource_admission_v2`; upgrade Core and native SDK together. Old
whole-PC claims migrate as exclusive reservations until verified cleanup.
