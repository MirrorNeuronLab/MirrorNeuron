# AGENTS.md

You are working on `MirrorNeuron`, an Elixir/BEAM runtime for long-lived, message-driven multi-agent workflows.

Read this file before making changes. Follow the existing codebase closely and prefer small, idiomatic edits over broad rewrites.

## Core Mandates

- Match existing project conventions before introducing new structure.
- Inspect adjacent code, tests, and docs before editing.
- Do not assume a library, framework pattern, or dependency is appropriate just because it is common elsewhere.
- Do not add new dependencies unless the user explicitly asks or the current approach is clearly impossible.
- Keep comments sparse and high value. Explain why, not what.
- Do not revert unrelated local changes.
- Finish the loop when practical: code, tests, formatting, and brief docs updates if behavior changed.

## Project Snapshot

MirrorNeuron is built around a strict boundary:

- BEAM handles orchestration, supervision, routing, clustering, persistence, and observability.
- Isolated execution is delegated to the sandbox / OpenShell path used by `executor` nodes.

The runtime is intentionally small and generic. It is not a home for product-specific agents.

### Runtime principles

- Agents are long-lived processes.
- Workflows are defined by manifest-driven graphs.
- Messages are explicit envelopes.
- Supervision is preferred over defensive complexity.
- CLI and operator visibility matter as much as raw execution.

## What Exists Today

MirrorNeuron already includes:

- built-in primitives: `router`, `executor`, `aggregator`, `sensor`
- agent templates: `generic`, `stream`, `map`, `reduce`, `batch`, `accumulator`
- Redis-backed persistence for job state, snapshots, and event history
- cluster support through `libcluster` and `Horde`
- a terminal-first CLI and monitor flow

Prefer extending the existing primitives and templates before inventing new top-level concepts.

## Project Structure

Important paths:

- `mix.exs`: project config and dependencies
- `lib/mirror_neuron/application.ex`: OTP application startup
- `lib/mirror_neuron.ex`: public runtime-facing API
- `lib/mirror_neuron/manifest.ex`: manifest loading, normalization, and validation
- `lib/mirror_neuron/message.ex`: runtime message envelope shape
- `lib/mirror_neuron/job_bundle.ex`: job bundle loading
- `lib/mirror_neuron/runtime/`: job coordinator, supervisors, event bus, runtime wiring
- `lib/mirror_neuron/builtins/`: runtime primitives such as router/executor/aggregator/sensor
- `lib/mirror_neuron/agent_templates/`: reusable workflow behavior templates
- `lib/mirror_neuron/cli/`: CLI commands, output formatting, and UI
- `lib/mirror_neuron/cluster/`: cluster membership and control
- `lib/mirror_neuron/persistence/redis_store.ex`: persistence adapter
- `lib/mirror_neuron/sandbox/`: sandbox and OpenShell integration
- `lib/mirror_neuron/execution/`: execution lease management
- `docs/`: user and operator documentation
- `examples/`: runnable example bundles
- `test/`: ExUnit coverage for runtime, CLI, manifests, and templates

## Where To Start By Task

If the request is about manifests:

- inspect `lib/mirror_neuron/manifest.ex`
- inspect `lib/mirror_neuron/job_bundle.ex`
- inspect `test/mirror_neuron/manifest_test.exs`
- update example bundles if manifest semantics change

If the request is about runtime lifecycle, job states, or supervision:

- inspect `lib/mirror_neuron/runtime/job_coordinator.ex`
- inspect `lib/mirror_neuron/runtime/job_runner.ex`
- inspect `lib/mirror_neuron/runtime/agent_worker.ex`
- inspect `lib/mirror_neuron/runtime/job_supervisor.ex`
- inspect `test/mirror_neuron/runtime_test.exs`

If the request is about built-in agent behavior:

- inspect `lib/mirror_neuron/builtins/`
- inspect `lib/mirror_neuron/agent_templates/`
- inspect `test/mirror_neuron/agent_templates_test.exs`
- keep the runtime generic; avoid domain-specific built-ins

If the request is about CLI behavior:

- inspect `lib/mirror_neuron/cli.ex`
- inspect `lib/mirror_neuron/cli/commands/`
- inspect `lib/mirror_neuron/cli/output.ex`
- inspect `lib/mirror_neuron/cli/ui.ex`
- inspect `test/mirror_neuron/cli_ui_test.exs`

If the request is about persistence or recovery:

- inspect `lib/mirror_neuron/persistence/redis_store.ex`
- inspect `lib/mirror_neuron/redis.ex`
- inspect runtime coordinator and event bus interactions

If the request is about clustering or remote control:

- inspect `lib/mirror_neuron/cluster/`
- inspect `lib/mirror_neuron/distributed_registry.ex`
- inspect `lib/mirror_neuron/rpc.ex`

If the request is about sandboxed execution:

- inspect `lib/mirror_neuron/sandbox/`
- inspect `lib/mirror_neuron/execution/lease_manager.ex`
- inspect `lib/mirror_neuron/builtins/executor.ex`

## Development Workflow

Typical local loop:

```bash
mix deps.get
mix format
mix test
mix escript.build
```

Useful CLI checks:

```bash
./mirror_neuron validate examples/research_flow
./mirror_neuron run examples/research_flow
./mirror_neuron inspect nodes
./mirror_neuron monitor
```

When Redis-backed tests or runtime flows are needed:

```bash
docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7
mix test
```

Some sandbox behavior also depends on OpenShell being available. If a test or manual check needs it and it is missing, say so clearly.

## Coding Guidance

### Elixir / OTP

- Prefer small functions with clear pattern matching over deeply nested conditionals.
- Follow the current OTP style used in the touched module.
- Use supervision and message passing rather than ad hoc retry loops.
- Keep process state explicit and serializable when possible.
- Preserve current naming and alias/import style from nearby modules.

### Runtime design

- Keep control-plane messages small and explicit.
- Preserve the separation between orchestration and isolated execution.
- Do not bypass manifest validation when adding manifest features.
- Do not sneak business-specific behavior into the runtime kernel.
- Prefer extending templates or config-driven behavior over branching the core runtime.

### Manifests and schemas

- Backward compatibility matters.
- Normalize inputs before validating where appropriate.
- Reject malformed manifests early with helpful errors.
- If manifest semantics change, update examples and relevant docs.

### CLI and UX

- Default output should remain readable for humans.
- Machine-readable output should stay stable if exposed publicly.
- Error messages should be direct and actionable.

## Testing Expectations

- Add or update tests for every meaningful behavior change.
- Prefer the narrowest tests that cover the change.
- Update unit tests first, then run broader verification as needed.
- If you change CLI behavior, add or adjust CLI-facing tests.
- If you change manifest validation, add both happy-path and failure-path coverage.
- If you change recovery or lifecycle behavior, verify the event/status transitions.

At minimum, after code changes run:

```bash
mix format
mix test
```

If the change affects the executable or command surface, also run:

```bash
mix escript.build
```

## Docs Expectations

If you add or change a user-visible feature, update the relevant docs:

- `README.md` for top-level usage changes
- `docs/cli.md` for command behavior
- `docs/api.md` for public inspection/control API changes
- `docs/development.md` for contributor workflow changes
- `examples/` when examples should demonstrate the new behavior

## Good Change Shape

Aim for this sequence:

1. Read the relevant module, adjacent modules, and tests.
2. Make the smallest idiomatic change that satisfies the request.
3. Add or update tests near the changed behavior.
4. Run formatting and tests.
5. Update docs only where behavior or operator expectations changed.

## Avoid

- broad refactors unrelated to the task
- new dependencies without strong justification
- business-specific agent types in the core runtime
- bypassing persistence or event publication in lifecycle changes
- changing public CLI semantics silently
- speculative abstractions that are not yet needed

## Handy References

- `README.md`
- `docs/development.md`
- `docs/runtime-architecture.md`
- `docs/reliability.md`
- `docs/cli.md`
- `docs/api.md`
