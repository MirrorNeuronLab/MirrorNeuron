# Stable Jobs and Execution Runs

MirrorNeuron separates a configured job from each time that job executes.

```text
stable job: job-7f3a
  persistent data: $MN_HOME/job-data/job-7f3a/
  run: run-20260722-a   (manual, completed)
  run: run-20260723-b   (scheduled, running)
  run: run-20260724-c   (manual, cancelled)
```

## Identity contract

- `job_id` identifies the durable job definition. It remains stable across
  configuration updates, schedules, restarts, and executions.
- `run_id` identifies one intentional execution and is the identity used by
  pause, resume, cancel, logs, events, artifacts, retention, and deletion.
- `attempt_id` identifies a retry or recovery attempt. A retry keeps its
  `run_id`; it does not create another execution.
- The v1 `/jobs/{id}` and original `JobService` surfaces are execution-oriented.
  Their historical `job_id` is treated as a `run_id`. The v2 service is the
  authoritative stable-job API.

Code must never infer that a job and a run are one-to-one. A job can have no
runs, one run, or many runs. A run belongs to exactly one job.

## Persistent and transient storage

Core derives storage paths from validated identifiers; callers cannot supply a
host job-data path.

| Scope | Default path | Lifetime |
| --- | --- | --- |
| Job data | `$MN_HOME/job-data/<job-id>/` | Until an explicit data reset or confirmed job deletion |
| Run data | `$MN_HOME/runs/<run-id>/` | Subject to run completion, retention, and run deletion |

Run cleanup may remove submissions, sandboxes, logs, outputs, and artifacts
owned by that run. It must not remove job data. Archiving prevents new work but
retains job data. Confirmed job deletion is refused while active runs exist and
then removes both the definition and its persistent data.

Resetting job data deletes and recreates the job directory, reapplies declared
bundle seeds, and increments `data_generation`. Runs retain the generation they
opened so stale handles are visible and cannot be mistaken for the new state.

## Declaring shared resources

A blueprint declares resources in `manifest.json`:

```json
{
  "metadata": {
    "job_data": {
      "resources": [
        {
          "name": "knowledge",
          "path": "knowledge",
          "access": "read_write",
          "seed": "@/payloads/knowledge"
        },
        {
          "name": "rag",
          "path": "databases/rag",
          "access": "read_write"
        },
        {
          "name": "state",
          "path": "state",
          "access": "read_write"
        }
      ]
    }
  }
}
```

Resource names and relative paths use validated identifier components. Seed
paths must use `@/`, resolve inside the archived bundle, name a directory, and
contain no symlinks. Seeds are copied only during initialization or an explicit
reset. A later run never overwrites user-edited knowledge.

Mutable file-backed databases are node-affine: the stable job records an owner
node and runs that consume its data are placed there. Replication is suitable
for backup or transfer, not simultaneous transactional access. Isolated workers
receive only the current run directory and current job-data directory, with the
declared read-only or read-write mode.

## Runtime environment

Every v2 run receives:

| Variable | Meaning |
| --- | --- |
| `MN_JOB_ID` | Stable job identity |
| `MN_RUN_ID` | Current execution identity |
| `MN_ATTEMPT_ID` | Current retry/recovery attempt identity |
| `MN_JOB_DATA_DIR` | Derived persistent job-data directory |
| `MN_JOB_DATA_ACCESS` | Effective `read_only` or `read_write` access |
| `MN_JOB_DATA_GENERATION` | Generation opened by the run; changes only after explicit reset |

SDK and payload code must use `MN_RUN_ID` for execution state. There is no
fallback from `MN_JOB_ID` to a run identity.

## Lifecycle operations

The versioned v2 gRPC service is defined in `proto/job_v2.proto` and exposed by
the API under `/api/v2`.

Stable job operations:

- create, inspect, list, and update a definition;
- archive while retaining data;
- reset data and advance its generation;
- confirmed deletion after active runs stop;
- start and list runs;
- create schedules that target the stable `job_id`.

Stable-job responses are bounded projections of the persisted definition. They
return lifecycle/configuration fields and a durable `bundle_ref`, but never
echo the expanded executable manifest or private runtime paths over gRPC.
List and mutation responses use summaries; inspect adds resolved configuration,
storage, and schedule fields. Run IDs are exposed by the dedicated list-runs
operation rather than copied into every job response. Run and schedule
responses follow the same rule: large manifests, workflow state, results, and
dispatch histories remain in durable storage and are represented by bounded
metadata or references.

Run operations:

- inspect, pause, resume, and cancel by `run_id`;
- confirmed deletion of an individual terminal run.

Each manual or scheduled dispatch creates a fresh `run_id`. Retry and recovery
advance attempt metadata while preserving the run identity, stable job-data
mount, access mode, and data generation. Bundles prepared by a blueprint layer
may contain a bootstrap/previous run ID; Core rebinds that ID throughout the
manifest and merges the job's current resolved configuration into
`MN_BLUEPRINT_CONFIG_JSON` before starting each run.

## Compatibility and migration

New clients should use v2. The v1 execution API remains readable and
controllable for historical records and maps its old execution identifier to a
run. New state is not permanently dual-written into two job models.

Desktop co-worker records migrate as follows:

- the old runtime `jobId` becomes `legacyExecutionId` on the latest run;
- the stable `jobId` is populated when the co-worker is next created or run;
- runtime control uses `legacyExecutionId` for old records and `runId` for v2;
- schedules retain the stable job and replace only the latest run identity.

Blueprint-scoped Milvus Lite data is not guessed when multiple destination
jobs are possible. An explicitly confirmed migration copies an unambiguous
inactive database to the job directory, verifies a checksum, and atomically
activates it. The legacy copy is removed only after a later open validates the
job-scoped collection.

## Safety invariants

- Validate all job and run IDs before deriving paths or persistence keys.
- Reject path traversal, symlink roots, symlink seeds, caller-owned host paths,
  and cross-job artifact references.
- Never delete job data as part of run cancellation, retention, or deletion.
- Never reset or delete job data while a run is active.
- Use `run_id` for delivery, ledgers, events, leases, supervision, and runtime
  controls; use `job_id` only for definition and shared-data ownership.
- Keep Syncthing and similar replication out of transactional database access.

## Verification focus

Tests should prove one job can create multiple independent runs sharing one
job-data directory, while two jobs built from the same blueprint remain
isolated. They should also cover restart, scheduled dispatch, retries, stale
generation handles, active-run lifecycle rejection, exact sandbox mounts,
forged identifiers, migration idempotency, and v1 historical reads.
