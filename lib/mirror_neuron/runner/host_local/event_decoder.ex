defmodule MirrorNeuron.Runner.HostLocal.EventDecoder do
  @moduledoc "Parses chunked SDK activity and beacon lines independently from captured command output."

  alias MirrorNeuron.Runner.HostLocal.Beacons

  def filter_beacon_output(data, state) do
    combined = state.line_buffer <> data
    parts = :binary.split(combined, "\n", [:global])
    complete_count = length(parts) - 1
    complete_lines = Enum.take(parts, complete_count)
    trailing = List.last(parts) || ""

    {clean_lines, next_state} =
      Enum.reduce(complete_lines, {[], %{state | line_buffer: trailing}}, fn line,
                                                                             {acc, current_state} ->
        line = String.trim_trailing(line, "\r")

        cond do
          String.starts_with?(line, current_state.event_prefix) ->
            {"", parsed_state} = handle_agent_event_line(line, current_state)
            {acc, parsed_state}

          String.starts_with?(line, current_state.prefix) ->
            {"", parsed_state} = handle_agent_beacon_line(line, current_state)
            {acc, parsed_state}

          true ->
            {[line | acc], current_state}
        end
      end)

    clean_output =
      clean_lines
      |> Enum.reverse()
      |> Enum.map(&(&1 <> "\n"))
      |> IO.iodata_to_binary()

    {clean_output, next_state}
  end

  def flush_beacon_buffer(%{line_buffer: ""} = state), do: {"", state}

  def flush_beacon_buffer(state) do
    line = String.trim_trailing(state.line_buffer, "\r")

    cond do
      String.starts_with?(line, state.event_prefix) ->
        {"", next_state} = handle_agent_event_line(line, state)
        {"", %{next_state | line_buffer: ""}}

      String.starts_with?(line, state.prefix) ->
        {"", next_state} = handle_agent_beacon_line(line, state)
        {"", %{next_state | line_buffer: ""}}

      true ->
        {state.line_buffer, %{state | line_buffer: ""}}
    end
  end

  defp handle_agent_event_line(line, state) do
    raw_payload =
      line
      |> String.replace_prefix(state.event_prefix, "")
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
                  Beacons.now_ms()
                )
          }

        _ ->
          state
      end

    case decoded do
      {:ok, %{"type" => event_type, "payload" => payload}}
      when is_binary(event_type) and event_type != "" and is_map(payload) ->
        Beacons.emit_beacon_event(state, event_type, Beacons.agent_event_payload(state, payload))

      {:ok, payload} when is_map(payload) ->
        event_type =
          case Map.get(payload, "type") do
            type when is_binary(type) and type != "" -> type
            _ -> "agent_activity"
          end

        Beacons.emit_beacon_event(
          state,
          event_type,
          Beacons.agent_event_payload(state, Map.drop(payload, ["type"]))
        )

      _ ->
        Beacons.emit_beacon_event(
          state,
          "agent_activity",
          Beacons.agent_event_payload(state, %{"message" => raw_payload, "category" => "agent"})
        )
    end

    {"", state}
  end

  defp handle_agent_beacon_line(line, state) do
    raw_payload =
      line
      |> String.replace_prefix(state.prefix, "")
      |> String.trim()

    decoded =
      case Jason.decode(raw_payload) do
        {:ok, payload} when is_map(payload) -> payload
        _ -> %{"message" => raw_payload}
      end

    now = Beacons.now_ms()

    payload =
      Beacons.beacon_payload(
        state,
        Map.get(decoded, "status", "working"),
        Map.get(decoded, "source", "agent"),
        now,
        decoded
      )

    Beacons.emit_beacon_event(state, :agent_beacon, payload)
    budget = MirrorNeuron.Runner.CommandBudget.observe(state.budget, :agent_beacon, payload, now)
    {"", %{state | sequence: state.sequence + 1, last_agent_beacon_at: now, budget: budget}}
  end
end
