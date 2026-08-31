defmodule MirrorNeuron.Grpc.Handlers.ObservabilityTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Grpc.Handlers.Observability
  alias Mirrorneuron.Observability.V1.{EventResponse, StreamEventsRequest}

  test "relays a remote owner's workflow events without consulting local storage" do
    request = %StreamEventsRequest{job_id: "run-remote", follow: false, version: 1}
    stream = %{metadata: %{}}
    parent = self()

    relay = fn owner, ^request, emit ->
      assert owner == "mirror_neuron@spark"
      emit.(%EventResponse{event_json: ~s({"type":"step_completed"}), version: 1})
      :ok
    end

    send_reply = fn ^stream, response ->
      send(parent, {:relayed, response})
      :ok
    end

    assert Observability.stream_events(request, stream,
             owner_lookup: fn "run-remote" -> "mirror_neuron@spark" end,
             relay: relay,
             send_reply: send_reply,
             local_stream: fn _request, _stream ->
               flunk("remote events must not read local storage")
             end
           ) == stream

    assert_receive {:relayed,
                    %EventResponse{event_json: ~s({"type":"step_completed"}), version: 1}}
  end

  test "keeps locally owned and legacy streams on the existing local path" do
    request = %StreamEventsRequest{job_id: "run-local", follow: false, version: 1}
    stream = %{metadata: %{}}

    assert Observability.stream_events(request, stream,
             owner_lookup: fn "run-local" -> nil end,
             local_stream: fn ^request, ^stream -> {:local, stream} end,
             relay: fn _owner, _request, _emit -> flunk("local events must not be relayed") end
           ) == {:local, stream}
  end

  test "rejects a second federation hop instead of creating a relay loop" do
    request = %StreamEventsRequest{job_id: "run-forwarded", follow: true, version: 1}
    stream = %{metadata: %{"x-mn-federation-hop" => "1"}}

    assert_raise GRPC.RPCError, ~r/MN_FEDERATION_LOOP/, fn ->
      Observability.stream_events(request, stream,
        owner_lookup: fn "run-forwarded" -> "mirror_neuron@other" end,
        relay: fn _owner, _request, _emit -> flunk("looping stream must not be relayed") end
      )
    end
  end
end
