defmodule MirrorNeuron.Runner.DockerWorker.Observations do
  @moduledoc "Parses chunked SDK observations and emits identity-bound worker and command events."

  @default_agent_event_prefix "__MN_EVENT__"

  def agent_event_state(config, opts) do
    environment =
      Map.merge(
        Map.get(config, "environment", %{}),
        MirrorNeuron.Runner.WorkflowEnvironment.from_options(opts)
      )

    %{
      prefix: agent_event_prefix(config),
      line_buffer: "",
      event_callback: Keyword.get(opts, :event_callback),
      job_id: to_string(Keyword.get(opts, :job_id, "")),
      agent_id: to_string(Keyword.get(opts, :agent_id, "")),
      step:
        to_string(
          Map.get(environment, "MN_WORKFLOW_STEP_ID") ||
            Keyword.get(opts, :agent_id, "")
        ),
      attempt: Keyword.get(opts, :attempt, 1)
    }
  end

  defp agent_event_prefix(config) do
    case Map.get(config, "agent_event_stdout_prefix") do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> @default_agent_event_prefix
    end
  end

  def filter_agent_event_output(data, state) do
    combined = state.line_buffer <> data
    parts = :binary.split(combined, "\n", [:global])
    complete_count = length(parts) - 1
    complete_lines = Enum.take(parts, complete_count)
    trailing = List.last(parts) || ""

    {clean_lines, next_state} =
      Enum.reduce(complete_lines, {[], %{state | line_buffer: trailing}}, fn line,
                                                                             {acc, current_state} ->
        line = String.trim_trailing(line, "\r")

        if String.starts_with?(line, current_state.prefix) do
          {acc, emit_agent_event_line(line, current_state)}
        else
          if String.starts_with?(line, "__MN_AGENT_BEACON__") do
            case Jason.decode(String.replace_prefix(line, "__MN_AGENT_BEACON__", "")) do
              {:ok, payload} when is_map(payload) ->
                payload = agent_event_payload(current_state, payload)
                emit_event(current_state, "agent_beacon", payload)

                budget =
                  MirrorNeuron.Runner.CommandBudget.observe(
                    current_state.budget,
                    "agent_beacon",
                    payload,
                    System.monotonic_time(:millisecond)
                  )

                {acc, %{current_state | budget: budget}}

              _ ->
                {acc, current_state}
            end
          else
            {[line | acc], current_state}
          end
        end
      end)

    clean_output =
      clean_lines
      |> Enum.reverse()
      |> Enum.map(&(&1 <> "\n"))
      |> IO.iodata_to_binary()

    {clean_output, next_state}
  end

  def flush_agent_event_buffer(%{line_buffer: ""} = state), do: {"", state}

  def flush_agent_event_buffer(state) do
    line = String.trim_trailing(state.line_buffer, "\r")

    if String.starts_with?(line, state.prefix) or
         String.starts_with?(line, "__MN_AGENT_BEACON__") do
      filter_agent_event_output(line <> "\n", %{state | line_buffer: ""})
    else
      {state.line_buffer, %{state | line_buffer: ""}}
    end
  end

  defp emit_agent_event_line(line, state) do
    raw_payload =
      line
      |> String.replace_prefix(state.prefix, "")
      |> String.trim()

    decoded = Jason.decode(raw_payload)

    state =
      case decoded do
        {:ok, %{"type" => type, "payload" => payload}}
        when is_binary(type) and type != "" and is_map(payload) ->
          %{
            state
            | budget:
                MirrorNeuron.Runner.CommandBudget.observe(
                  state.budget,
                  type,
                  payload,
                  System.monotonic_time(:millisecond)
                )
          }

        _ ->
          state
      end

    case decoded do
      {:ok, %{"type" => event_type, "payload" => payload}}
      when is_binary(event_type) and event_type != "" and is_map(payload) ->
        emit_event(state, event_type, agent_event_payload(state, payload))

      {:ok, payload} when is_map(payload) ->
        event_type =
          case Map.get(payload, "type") do
            type when is_binary(type) and type != "" -> type
            _ -> "agent_activity"
          end

        emit_event(
          state,
          event_type,
          agent_event_payload(state, Map.drop(payload, ["type"]))
        )

      _ ->
        emit_event(
          state,
          "agent_activity",
          agent_event_payload(state, %{"message" => raw_payload, "category" => "agent"})
        )
    end

    state
  end

  defp agent_event_payload(state, payload) do
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

  def emit_runner_event(opts, event_type, payload) do
    case Keyword.get(opts, :event_callback) do
      callback when is_function(callback, 2) ->
        callback.(event_type, runner_event_payload(opts, payload))

      _ ->
        :ok
    end

    :ok
  end

  defp runner_event_payload(opts, payload) do
    agent_id = to_string(Keyword.get(opts, :agent_id, ""))

    Map.merge(
      %{
        "schema" => "mn.agent.activity.v1",
        "agent_id" => agent_id,
        "step" => agent_id,
        "step_id" => agent_id,
        "source" => "runtime",
        "category" => Map.get(payload, "category", "system"),
        "emitted_at" => MirrorNeuron.Runtime.timestamp()
      },
      payload
    )
  end

  defp emit_event(%{event_callback: callback}, event_type, payload)
       when is_function(callback, 2) do
    callback.(event_type, payload)
  end

  defp emit_event(_state, _event_type, _payload), do: :ok
end
