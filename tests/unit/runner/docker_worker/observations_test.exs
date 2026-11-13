defmodule MirrorNeuron.Runner.DockerWorker.ObservationsTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.CommandBudget
  alias MirrorNeuron.Runner.DockerWorker.Observations

  test "fragmented SDK events are delivered once and removed from captured output" do
    assert {"before\n", state} =
             Observations.filter_agent_event_output("before\n__MN_EV", state())

    refute_received {:event, _, _}

    assert {"after\n", _} =
             Observations.filter_agent_event_output(
               ~s(ENT__{"type":"done","payload":{"message":"ok"}}\nafter\n),
               state
             )

    assert_receive {:event, "done", %{"message" => "ok"}}
    refute_received {:event, _, _}
  end

  test "the final beacon without a newline is processed and stripped" do
    line = ~s(__MN_AGENT_BEACON__{"source":"agent","progress_sequence":1})
    assert {"", state} = Observations.filter_agent_event_output(line, state())
    assert {"", state} = Observations.flush_agent_event_buffer(state)
    assert state.line_buffer == ""
    assert_receive {:event, "agent_beacon", %{"progress_sequence" => 1}}
  end

  test "invalid event types do not crash either observation or budget processing" do
    for type <- [%{}, [], 123, nil],
        payload <- [%{"message" => "invalid"}, %{"payload" => %{}}] do
      line = "__MN_EVENT__" <> Jason.encode!(Map.put(payload, "type", type)) <> "\n"
      assert {"", _} = Observations.filter_agent_event_output(line, state())
      assert_receive {:event, "agent_activity", %{}}
    end
  end

  test "worker data cannot change execution ownership fields" do
    forged = %{"job_id" => "other", "agent_id" => "other", "attempt" => 99, "source" => "runtime"}
    line = "__MN_EVENT__" <> Jason.encode!(%{"type" => "done", "payload" => forged}) <> "\n"
    assert {"", _} = Observations.filter_agent_event_output(line, state())

    assert_receive {:event, "done",
                    %{
                      "job_id" => "job",
                      "agent_id" => "worker",
                      "attempt" => 2,
                      "source" => "agent"
                    }}
  end

  test "ordinary trailing text is flushed once without inventing a newline" do
    {"", state} = Observations.filter_agent_event_output("tail", state())
    assert {"tail", state} = Observations.flush_agent_event_buffer(state)
    assert {"", _} = Observations.flush_agent_event_buffer(state)
  end

  defp state do
    parent = self()

    Observations.agent_event_state(%{},
      job_id: "job",
      agent_id: "worker",
      attempt: 2,
      event_callback: fn type, payload -> send(parent, {:event, type, payload}) end
    )
    |> Map.put(:budget, CommandBudget.new(nil, %{}, System.monotonic_time(:millisecond)))
  end
end
