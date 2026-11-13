defmodule MirrorNeuron.Runner.HostLocal.Beacons do
  @moduledoc "Runtime liveness state and fenced agent observation payloads."

  alias MirrorNeuron.Runner.HostLocal.Context

  @beacon_prefix "__MN_AGENT_BEACON__"
  @default_beacon_interval_ms 15_000
  @default_beacon_timeout_ms 45_000

  def beacon_env(config, opts, message) do
    if truthy?(Map.get(config, "beacon_enabled")) do
      interval_ms =
        positive_int(Map.get(config, "beacon_interval_ms"), @default_beacon_interval_ms)

      timeout_ms = positive_int(Map.get(config, "beacon_timeout_ms"), @default_beacon_timeout_ms)
      required = truthy?(Map.get(config, "agent_beacon_required"))
      environment = Map.get(config, "environment", %{})
      workflow = Context.workflow_context(message)

      %{
        "MN_AGENT_BEACON_STDOUT_PREFIX" => beacon_prefix(config),
        "MN_AGENT_BEACON_INTERVAL_MS" => to_string(interval_ms),
        "MN_AGENT_BEACON_TIMEOUT_MS" => to_string(timeout_ms),
        "MN_AGENT_BEACON_REQUIRED" => if(required, do: "1", else: "0"),
        "MN_AGENT_BEACON_JOB_ID" => to_string(Keyword.get(opts, :job_id, "")),
        "MN_AGENT_BEACON_AGENT_ID" => to_string(Keyword.get(opts, :agent_id, "")),
        "MN_AGENT_BEACON_ATTEMPT" =>
          to_string(Map.get(workflow, "attempt") || Keyword.get(opts, :attempt, 1)),
        "MN_AGENT_BEACON_STEP" =>
          to_string(
            Map.get(workflow, "step_id") ||
              Map.get(environment, "MN_WORKFLOW_STEP_ID") ||
              Keyword.get(opts, :agent_id, "")
          ),
        "MN_AGENT_BEACON_SOURCE" => "agent"
      }
    else
      %{}
    end
  end

  def beacon_state(config, opts, message) do
    now = now_ms()
    interval_ms = positive_int(Map.get(config, "beacon_interval_ms"), @default_beacon_interval_ms)
    timeout_ms = positive_int(Map.get(config, "beacon_timeout_ms"), @default_beacon_timeout_ms)
    environment = Map.get(config, "environment", %{})
    workflow = Context.workflow_context(message)

    %{
      enabled: truthy?(Map.get(config, "beacon_enabled")),
      required: truthy?(Map.get(config, "agent_beacon_required")),
      interval_ms: interval_ms,
      timeout_ms: timeout_ms,
      prefix: beacon_prefix(config),
      event_prefix: agent_event_prefix(config),
      line_buffer: "",
      sequence: 0,
      job_id: to_string(Keyword.get(opts, :job_id, "")),
      agent_id: to_string(Keyword.get(opts, :agent_id, "")),
      step:
        to_string(
          Map.get(workflow, "step_id") ||
            Map.get(environment, "MN_WORKFLOW_STEP_ID") ||
            Keyword.get(opts, :agent_id, "")
        ),
      attempt: Map.get(workflow, "attempt") || Keyword.get(opts, :attempt, 1),
      event_callback: Keyword.get(opts, :event_callback),
      started_at: now,
      last_agent_beacon_at: now,
      next_runtime_beacon_at: now + interval_ms
    }
  end

  defp beacon_prefix(config) do
    case Map.get(config, "agent_beacon_stdout_prefix") do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> @beacon_prefix
    end
  end

  defp agent_event_prefix(config) do
    case Map.get(config, "agent_event_stdout_prefix") do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> "__MN_EVENT__"
    end
  end

  def maybe_emit_runtime_beacon(%{enabled: false} = state, _now), do: state

  def maybe_emit_runtime_beacon(state, now) do
    if now >= state.next_runtime_beacon_at do
      state
      |> emit_runtime_beacon("working", now)
      |> Map.update!(
        :next_runtime_beacon_at,
        &max(&1 + state.interval_ms, now + state.interval_ms)
      )
    else
      state
    end
  end

  def emit_runtime_beacon(state, status, now \\ now_ms())

  def emit_runtime_beacon(%{enabled: false} = state, _status, _now), do: state

  def emit_runtime_beacon(state, status, now) do
    payload = beacon_payload(state, status, "runtime", now)
    emit_beacon_event(state, :agent_beacon, payload)
    %{state | sequence: state.sequence + 1}
  end

  def beacon_payload(state, status, source, now, extra \\ %{}) do
    Map.merge(
      %{
        "schema" => "mn.agent.beacon.v1",
        "job_id" => state.job_id,
        "agent_id" => state.agent_id,
        "step" => state.step,
        "attempt" => state.attempt,
        "source" => source,
        "status" => status,
        "sequence" => state.sequence,
        "message" => Map.get(extra, "message", default_beacon_message(source, status)),
        "interval_ms" => state.interval_ms,
        "timeout_ms" => state.timeout_ms,
        "elapsed_ms" => max(now - state.started_at, 0),
        "ms_since_last_agent_beacon" => max(now - state.last_agent_beacon_at, 0),
        "emitted_at" => MirrorNeuron.Runtime.timestamp()
      },
      Map.drop(extra, [
        "schema",
        "job_id",
        "agent_id",
        "step",
        "attempt",
        "source",
        "status",
        "sequence",
        "interval_ms",
        "timeout_ms",
        "elapsed_ms",
        "ms_since_last_agent_beacon",
        "emitted_at"
      ])
    )
  end

  def agent_event_payload(state, payload) do
    Map.merge(
      %{
        "schema" => "mn.agent.activity.v1",
        "job_id" => state.job_id,
        "agent_id" => state.agent_id,
        "step" => state.step,
        "step_id" => state.step,
        "attempt" => state.attempt,
        "source" => "agent",
        "category" => Map.get(payload, "category", "agent"),
        "emitted_at" => MirrorNeuron.Runtime.timestamp()
      },
      Map.drop(payload, [
        "schema",
        "job_id",
        "agent_id",
        "step",
        "step_id",
        "attempt",
        "source",
        "emitted_at"
      ])
    )
  end

  defp default_beacon_message("runtime", "started"), do: "HostLocal command started"

  defp default_beacon_message("runtime", "completed"), do: "HostLocal command completed"

  defp default_beacon_message("runtime", _status), do: "HostLocal command is still running"

  defp default_beacon_message("agent", "missed"), do: "Agent beacon deadline exceeded"

  defp default_beacon_message("agent", _status), do: "Agent is still working"

  defp default_beacon_message(_source, _status), do: "Worker is still running"

  def emit_beacon_event(%{event_callback: callback}, event_type, payload)
      when is_function(callback, 2) do
    callback.(event_type, payload)
  end

  def emit_beacon_event(_state, _event_type, _payload), do: :ok

  def beacon_missed?(%{enabled: true, required: true} = state, now) do
    now - state.last_agent_beacon_at >= state.timeout_ms
  end

  def beacon_missed?(_state, _now), do: false

  def now_ms, do: System.monotonic_time(:millisecond)

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp truthy?(value), do: value in [true, "true", "1", "yes"]
end
