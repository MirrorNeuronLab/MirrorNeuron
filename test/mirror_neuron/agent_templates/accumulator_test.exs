defmodule MirrorNeuron.AgentTemplates.AccumulatorTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.AgentTemplates.Accumulator

  test "delegates init to Reduce" do
    node = %{node_id: "acc_1", config: %{}}
    assert {:ok, state} = Accumulator.init(node, complete_on_message: true)
    assert state.complete_on_message == true
    assert state.messages == []
  end

  test "delegates collect to Reduce" do
    node = %{node_id: "acc_1", config: %{}}
    {:ok, state} = Accumulator.init(node)

    msg = %{
      "message_id" => "m1",
      "headers" => %{"from" => "w1"},
      "payload" => %{"value" => 1}
    }

    assert {:ok, new_state, actions} =
             Accumulator.collect(msg, state, build_result: fn msgs -> msgs end)

    assert new_state.messages == [%{"value" => 1}]
    assert actions == [{:event, :reducer_received, %{"count" => 1}}]
  end

  test "delegates should_complete? to Reduce" do
    node = %{node_id: "acc_1", config: %{}}
    {:ok, state} = Accumulator.init(node, complete_on_message: true)

    assert Accumulator.should_complete?(state, [%{}]) == true
  end
end
