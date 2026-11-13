defmodule MirrorNeuron.Runner.HostLocal.EventDecoderTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.CommandBudget
  alias MirrorNeuron.Runner.HostLocal.{Beacons, EventDecoder}

  test "a split event frame is delivered exactly once and excluded from stdout" do
    state = state()
    assert {"before\n", state} = EventDecoder.filter_beacon_output("before\n__MN_EV", state)
    refute_received {:event, _, _}

    assert {"after\n", state} =
             EventDecoder.filter_beacon_output(
               ~s(ENT__{"type":"tool_done","payload":{"message":"done"}}\nafter\n),
               state
             )

    assert_receive {:event, "tool_done", %{"message" => "done"}}
    refute_received {:event, _, _}
    assert {"", _} = EventDecoder.flush_beacon_buffer(state)
  end

  test "an event without a trailing newline is parsed even with runtime beacons disabled" do
    {"", state} =
      EventDecoder.filter_beacon_output(
        ~s(__MN_EVENT__{"type":"tool_done","payload":{"message":"last"}}),
        state()
      )

    assert {"", next} = EventDecoder.flush_beacon_buffer(state)
    assert next.line_buffer == ""
    assert_receive {:event, "tool_done", %{"message" => "last"}}
  end

  test "malformed event types cannot crash a command's output collector" do
    for type <- [%{}, [], 123, nil] do
      line = "__MN_EVENT__" <> Jason.encode!(%{"type" => type, "message" => "bad type"}) <> "\n"
      assert {"", _} = EventDecoder.filter_beacon_output(line, state())
      assert_receive {:event, "agent_activity", %{"message" => "bad type"}}

      nested = "__MN_EVENT__" <> Jason.encode!(%{"type" => type, "payload" => %{}}) <> "\n"
      assert {"", _} = EventDecoder.filter_beacon_output(nested, state())
      assert_receive {:event, "agent_activity", %{}}
    end
  end

  test "worker event data cannot replace the runner's execution identity" do
    payload = %{
      "job_id" => "forged",
      "agent_id" => "forged",
      "attempt" => 999,
      "step_id" => "forged",
      "source" => "runtime"
    }

    line = "__MN_EVENT__" <> Jason.encode!(%{"type" => "activity", "payload" => payload}) <> "\n"
    assert {"", _} = EventDecoder.filter_beacon_output(line, state())

    assert_receive {:event, "activity",
                    %{
                      "job_id" => "job",
                      "agent_id" => "worker",
                      "attempt" => 3,
                      "step_id" => "worker",
                      "source" => "agent"
                    }}
  end

  test "a final ordinary line is returned once without adding a newline" do
    {"", state} = EventDecoder.filter_beacon_output("last line", state())
    assert {"last line", state} = EventDecoder.flush_beacon_buffer(state)
    assert {"", _} = EventDecoder.flush_beacon_buffer(state)
    refute_received {:event, _, _}
  end

  test "CRLF event frames leave only normal command output" do
    line = ~s(__MN_EVENT__{"type":"done","payload":{}}\r\ntext\r\n)
    assert {"text\n", _} = EventDecoder.filter_beacon_output(line, state())
    assert_receive {:event, "done", %{}}
  end

  defp state do
    parent = self()

    Beacons.beacon_state(
      %{},
      [
        job_id: "job",
        agent_id: "worker",
        attempt: 3,
        event_callback: fn type, payload -> send(parent, {:event, type, payload}) end
      ],
      nil
    )
    |> Map.put(:budget, CommandBudget.new(nil, %{}, Beacons.now_ms()))
  end
end
