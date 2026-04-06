defmodule MirrorNeuron.Builtins.SensorTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.Sensor

  test "init sets up state correctly" do
    node = %{
      config: %{"complete_after" => 5}
    }

    assert {:ok, state} = Sensor.init(node)
    assert state.observations == 0
    assert state.complete_after == 5
  end

  test "handle_message emits and increments observations" do
    node = %{
      config: %{"output_message_type" => "test_ready"}
    }

    {:ok, state} = Sensor.init(node)

    msg = %{
      "message_id" => "msg1",
      "payload" => %{"data" => 123},
      "headers" => %{"x-test" => "1"},
      "content_type" => "application/json",
      "content_encoding" => "identity"
    }

    assert {:ok, next_state, actions} = Sensor.handle_message(msg, state, %{})
    assert next_state.observations == 1

    assert {:event, :sensor_observed, %{"count" => 1}} in actions

    emit_action =
      Enum.find(actions, fn
        {:emit, type, _, _} -> type == "test_ready"
        _ -> false
      end)

    assert {:emit, "test_ready", %{"data" => 123}, opts} = emit_action
    assert Keyword.get(opts, :headers) == %{"x-test" => "1"}
  end

  test "handle_message completes job if configured and threshold reached" do
    node = %{
      config: %{
        "complete_after" => 2,
        "complete_job" => true
      }
    }

    {:ok, state} = Sensor.init(node)

    msg = %{"message_id" => "m", "payload" => "hello"}

    # First observation
    {:ok, state1, actions1} = Sensor.handle_message(msg, state, %{})
    assert state1.observations == 1

    refute Enum.any?(actions1, fn
             {type, _} -> type == :complete_job
             _ -> false
           end)

    # Second observation
    {:ok, state2, actions2} = Sensor.handle_message(msg, state1, %{})
    assert state2.observations == 2

    complete_action =
      Enum.find(actions2, fn
        {:complete_job, _} -> true
        _ -> false
      end)

    assert {:complete_job, %{"count" => 2, "last_message" => "hello"}} = complete_action
  end
end
