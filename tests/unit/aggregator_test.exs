defmodule MirrorNeuron.AggregatorTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.Aggregator

  test "emits a collected aggregate result when output_message_type is configured" do
    node = %{
      config: %{
        "complete_after" => 2,
        "output_message_type" => "collected"
      }
    }

    {:ok, state0} = Aggregator.init(node)

    {:ok, state1, actions1} =
      Aggregator.handle_message(
        %{
          type: "prime_chunk_result",
          payload: %{"value" => 1}
        },
        state0,
        %{}
      )

    refute Enum.any?(actions1, &match?({:complete_job, _}, &1))

    {:ok, _state2, actions2} =
      Aggregator.handle_message(
        %{
          type: "prime_chunk_result",
          payload: %{"value" => 2}
        },
        state1,
        %{}
      )

    assert {:emit, "collected", result, _opts} =
             Enum.find(actions2, &match?({:emit, _, _, _}, &1))

    assert result["count"] == 2
    assert result["messages"] == [%{"value" => 1}, %{"value" => 2}]
    refute Enum.any?(actions2, &match?({:complete_job, _}, &1))
  end

  test "ignores duplicate replayed executor results by agent_id" do
    node = %{
      config: %{
        "complete_after" => 2,
        "output_message_type" => "collected"
      }
    }

    {:ok, state0} = Aggregator.init(node)

    {:ok, state1, actions1} =
      Aggregator.handle_message(
        %{type: "executor_result", payload: %{"agent_id" => "worker-1", "value" => 1}},
        state0,
        %{}
      )

    assert actions1 == [{:event, :aggregator_received, %{"count" => 1}}]

    {:ok, state2, actions2} =
      Aggregator.handle_message(
        %{type: "executor_result", payload: %{"agent_id" => "worker-1", "value" => 1}},
        state1,
        %{}
      )

    assert state2.messages == [%{"agent_id" => "worker-1", "value" => 1}]
    assert actions2 == [{:event, :aggregator_duplicate_ignored, %{"agent_id" => "worker-1"}}]

    {:ok, _state3, actions3} =
      Aggregator.handle_message(
        %{type: "executor_result", payload: %{"agent_id" => "worker-2", "value" => 2}},
        state2,
        %{}
      )

    assert {:emit, "collected", result, _opts} =
             Enum.find(actions3, &match?({:emit, _, _, _}, &1))

    assert result["count"] == 2
    assert Enum.map(result["messages"], & &1["agent_id"]) == ["worker-1", "worker-2"]
  end
end
