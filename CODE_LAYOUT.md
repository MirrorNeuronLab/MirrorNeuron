# Core code layout

Core keeps its public Elixir modules as entry points and groups implementation
by responsibility. Moving a file does not rename its module, process registration,
supervisor child ID, wire message, or persisted record. For example,
`MirrorNeuron.Runtime.JobCoordinator` still owns the coordinator GenServer even
though its implementation now lives under `runtime/job/`.

## Runtime domains

Paths in this table are relative to `lib/mirror_neuron/`.

| Directory | Responsibility | Entry point |
| --- | --- | --- |
| `runtime/control/` | Submission, public control calls, message delivery, cleanup | `runtime/runtime.ex` |
| `runtime/definition/` | Stable Job definitions, validation, run creation and history | `runtime/definition/stable_job.ex` |
| `runtime/job/` | Job processes, coordinator lifecycle, topology, finalization | `runtime/job/job_coordinator.ex`, `job_runner.ex` |
| `runtime/agent/` | Worker processes, invocation, delivery, retries, observations | `runtime/agent/agent_worker.ex` |
| `runtime/workflow/` | Logical steps, attempts, dependencies, dynamic graphs | `runtime/workflow/workflow_ledger.ex`, `dynamic_workflow.ex` |
| `runtime/delivery/` | Durable delivery, command receipts, live input, replies | `runtime/delivery/delivery.ex` |
| `runtime/deployment/` | Rollouts, promotion, readiness, deployment records | `runtime/deployment/deployment_controller.ex` |
| `runtime/recovery/` | Local recovery, relocation, cancellation, checkpoint retry | `runtime/recovery/local_recovery.ex`, `run_retry.ex` |
| `runtime/response/` | Response service lifecycle, warmup, queries and admission | `runtime/response/job_response.ex` |
| `runtime/interaction/` | Interactive requests and deadlines | `runtime/interaction/interactions.ex` |
| `runtime/observability/` | Events, errors, signals and reliability observations | `runtime/observability/signals.ex`, `error_monitor.ex` |

The coordinator delegates to `runtime/job/coordinator/` for lifecycle operations.
The ledger delegates to `runtime/workflow/ledger/` for state transitions and
projections. These helpers execute in their caller's process; extraction does
not add mailboxes, process ownership, or an alternative completion authority.
Only the owning step boundary completes a logical workflow step.

## Scheduling

Scheduling implementation lives in `lib/mirror_neuron/scheduler/`:

| Directory or file | Responsibility |
| --- | --- |
| `scheduler.ex` | Public placement entry point (`MirrorNeuron.Scheduler`) |
| `placement/` | Candidate selection, resource demand, scoring, allocations and recovery placement |
| `admission/` | Node reservations, resource admission, waiting queues and fencing |
| `resources/` | Resource requests, inventory, environment projection and validation (`MirrorNeuron.ResourceSpec`) |
| `execution_pools/` | Bounded executor pools, lease queues, expiry and caller monitoring (`MirrorNeuron.Execution.LeaseManager`) |
| `schedules/` | Cron/event dispatch, occurrences, stable Job schedules and service windows |
| `validation/` | Manifest scheduling policy validation |
| `grpc/` | Schedule RPCs and run admission responses |
| `monitoring.ex` | Scheduler diagnostic projection |

The existing `MirrorNeuron.Runtime` admission and schedule module names remain
valid. Redis schedule persistence remains in the persistence domain. Executor
pool leases and node resource reservations retain their separate existing
contracts; this layout does not add a GPU reservation within a Job.

## Definitions, persistence and adapters

| Directory | Responsibility | Stable entry point |
| --- | --- | --- |
| `manifest/` | Loading, shape validation, topology, workflow, completion and response declarations | `MirrorNeuron.Manifest` |
| `validation/` | Blueprint input rules, resource requirements, reports and redaction | `MirrorNeuron.BlueprintValidation` |
| `persistence/redis_store/` | Domain records, indexes, retention, Redis transport and result validation | `MirrorNeuron.Persistence.RedisStore` |
| `persistence/delivery_store/` | Atomic enqueue, claims, settlement, invocation journal and receipts | `MirrorNeuron.Persistence.DeliveryStore` |
| `cluster/reconciliation/` | Recovery evaluations, dispatch, node availability, retry timing | `MirrorNeuron.Cluster.Reconciler` |
| `cluster/draining/` | Node drain operations and state | `MirrorNeuron.Cluster.NodeDrainer` |
| `cluster/federation/` | Peer registry storage, tombstones, availability and projections | `MirrorNeuron.Cluster.FederationRegistry` |
| `cluster/hardware/` | Native snapshots, GPU parsing and hardware advertisement | `MirrorNeuron.Cluster.Hardware` |
| `model_services/` | Service advertisement, registration, preparation commands and requests | `MirrorNeuron.ModelServices` |
| `monitor/` | Job/agent views, bounded projections, metrics and control actions | `MirrorNeuron.Monitor` |
| `runner/host_local/` | Host command preparation, process ownership, streaming and uploads | `MirrorNeuron.Runner.HostLocal` |
| `runner/docker_worker/` | Container preparation, workspace, execution and output | `MirrorNeuron.Runner.DockerWorker` |
| `runner/open_shell/` | Sandbox invocation, transport, staging, uploads and policy paths | `MirrorNeuron.Runner.OpenShell` |
| `builtins/executor/` | Invocation, leases, event decoding, retry and artifact results | `MirrorNeuron.Builtins.Executor` |

The paths above are relative to `lib/mirror_neuron/`. Job gRPC operations live in
`lib/mirror_neuron_grpc/handlers/job/`, behind the existing
`MirrorNeuron.Grpc.Handlers.Job` facade. Protobuf sources and generated bindings
retain their existing locations.

## Tests

`tests/unit/` follows the same domain boundaries. Pure state transitions and
input validation are tested directly, while process tests use supervised local
processes. `tests/e2e/` covers durable persistence, runner transports and complete
runtime lifecycles. Shared fixtures live in `tests/support/`; tests using global
application configuration or named processes remain synchronous.

Use a disposable Redis instance for persistence and runtime tests. Select an
unused gRPC port and a dedicated namespace/home to avoid interfering with a
running developer node:

```bash
export MN_REDIS_URL=redis://127.0.0.1:16379/0
export MN_REDIS_PASSWORD=''
export MN_REDIS_NAMESPACE=core-tests
export MN_GRPC_PORT=15051
export MN_HOME="$(mktemp -d)"
mix test
```

Python handoff tests execute the SDK wrappers through a fake OpenShell transport.
They need the sibling `mn-python-sdk` checkout, including its common and
blueprint-blocks packages, and a compatible Python environment (Python 3.12 is
used for these checks). For an editable workspace, configure that interpreter
and source roots before running the suite:

```bash
export MN_TEST_PYTHON=/absolute/path/to/python-environment/bin/python
export PATH="$(dirname "$MN_TEST_PYTHON"):$PATH"
mn_sdk_root="$(cd ../mn-python-sdk && pwd)"
export PYTHONPATH="$mn_sdk_root:$mn_sdk_root/packages/common/src:$mn_sdk_root/packages/blueprint-blocks/src${PYTHONPATH:+:$PYTHONPATH}"
mix test tests/e2e/runner/open_shell/handoff tests/unit/block_event_runner_test.exs
```

The regular suite skips the durable flow fixtures, which start their own
supervision tree. Run those separately without starting the application:

```bash
MN_FLOW_REDIS_URL="$MN_REDIS_URL" mix test --no-start tests/e2e/runtime/flows
```

Do not set `MN_FLOW_REDIS_URL` for an ordinary application-started `mix test` run.
Real Docker lifecycle tests are opt-in with `MN_TEST_DOCKER_LIFECYCLE=1`; they
require a running Docker daemon and their configured image. Fake runner tests
do not establish that a live OpenShell gateway or a multi-machine federation
works in a deployment environment.

Required repository checks:

```bash
mix format --check-formatted
mix test
mix compile --warnings-as-errors
rg --files scripts -g '*.sh' -0 | xargs -0 -n1 bash -n
```
