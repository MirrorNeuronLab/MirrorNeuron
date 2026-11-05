# Job timeout ownership

Job lifetime is owned by Core. An API/CLI observer disconnect or an expired
transport read is not evidence that accepted work failed. The durable operation
or run receipt is the authority; observers reconnect to it without redispatch.

## Supervision

The default workflow `control.timeout_seconds` is 300 seconds. The SDK's
execution schema supplies this compilation default, and Core uses the same
default for workflows submitted directly. It is a soft inspection interval,
including when an author supplies a different interval.

At expiry Core records `workflow_step_inspection_started` and probes registered
worker ownership asynchronously. The entire probe is bounded to five seconds;
the persisted inspection has a ten-second watchdog. It never calls a busy
worker's GenServer mailbox. Pause, cancellation, delivery and other jobs remain
independent of this probe.

Core continues the same attempt only when the worker exists and its latest SDK
progress or bounded external wait proves more time is warranted. A new progress
sequence renews the inactivity allowance. Automatic heartbeats, repeated
counters and repeated wait identities cannot renew it. A bounded model, tool or
human wait has an immutable deadline, followed by the step's inactivity
allowance. SDK model requests advertise that wait around inference, after model
preparation has closed. The inference client's own operation deadline remains
in force.

A missing worker or expired progress fails the attempt. An unavailable ownership
probe gets one 30-second recheck; repeated uncertainty or an inspector which
never replies reports failure. Results are fenced by step, attempt and inspection
identity. Pause retires the pending inspection; recovery creates a fresh probe.
Late results cannot revive terminal, paused or replacement attempts. Normal
retry policy applies after failure, and all physical workers in the timed-out
step are retired before retry dispatch. Enclosing child-workflow controllers
follow the actual child workers' ownership and progress.

Only the owning step boundary commits completion. Neither progress nor a
successful inspection completes, replays or increments an attempt.

## Preparation and runner clocks

`runtime_preparation_started` and `runtime_preparation_finished` carry a current
attempt ID, unique preparation ID, kind (`model`, `dependencies`, `service`) and
finite timeout in milliseconds, at most one day. Duplicate starts cannot move
that deadline, and a late finish cannot erase an expired preparation. Core and
the command runners exclude the union of overlapping preparation intervals,
once, from execution/progress clocks. The gap between sequential preparations
still consumes execution time. Explicit liveness and cancellation remain active.

The same contract applies to HostLocal, DockerWorker, artifact-handoff OpenShell
and legacy OpenShell commands. All relay SDK protocol records live; remote
stdout/stderr are drained and bounded independently of the final durable result.
Remote process supervision also handles commands which close both output pipes
without exiting and descendants which retain inherited pipes. Local block
execution excludes the same setup intervals. The compiler does not copy a soft
workflow interval into a block's independent hard operation limit.

Staged-input verification runs in an owned asynchronous task. Its configured
1800-second default is an inactivity allowance: increasing observed input bytes
or newly verified files renew it. Repeated or fluctuating snapshots cannot renew
the high-water marks. Only complete size/digest verification admits work; a live
copy cannot bypass validation. A stalled verifier is bounded and cancelled with
its coordinator.

## Reviewed timeout boundaries

| Boundary | Owner and behavior |
| --- | --- |
| Blueprint preparation, additions and launch | API durable operations already run asynchronously. Poll/SSE observation does not limit their lifetime. |
| Workflow step and child step | Core soft deadline plus async ownership/progress inspection. |
| SDK lazy model/dependency/service preparation | Separate bounded preparation scope; excluded from workflow, block and runner execution time. |
| Model preparation RPC | Existing native operation allowance (1200 seconds by default), same request identity and one transport retry; scope covers both attempts. |
| Runtime package download/install | Independent 600-second subprocess bound; preparation failure closes its scope and preserves the actual error. |
| Model inference and explicitly budgeted tools/blocks | Their declared computation/network/call budgets remain enforced. Progress cannot silently increase a domain spending or simulation limit. |
| Host/Docker/OpenShell command execution | Monotonic inactivity clock, true SDK progress and bounded waits; preparation excluded. |
| SDK process beacons / explicit workflow heartbeat | Physical liveness remains independent from execution. An automatic beacon does not establish useful progress. |
| Staged-input replication and verification | Async verification and progress-aware inactivity bound; no entrypoint until integrity checks pass. |
| Workflow admission RPC | Timeout defers delivery; it does not declare the work failed or duplicate the invocation. |
| API/CLI desktop follow and transport requests | Observe/reconcile durable identities. Existing follow limits do not cancel accepted runs. |
| Native image/environment/OpenShell provisioning | Independent preparation operation budgets bound their owning subprocesses; these run before workflow execution. |
| Delivery leases, cleanup, shutdown, locks and resource admission | Keep their bounded lease/control semantics. They are not task execution limits and must not be extended by unrelated output. |

Deploy matching Core, SDK, common and blocks code before preparing future Jobs.
Already failed runs stay failed. Existing cached prepared workers must be
prepared with the updated components; no historical work is automatically
replayed. Rebuild the local Core image, then recreate the runtime container to
use the updated image. Restarting an old container alone retains its old image.
