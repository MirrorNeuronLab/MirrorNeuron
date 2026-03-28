defmodule MirrorNeuron.AggregatorCompletionTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.Aggregator

  test "completes after the configured message count" do
    node = %{
      config: %{
        "complete_on_message" => false,
        "complete_after" => 3
      }
    }

    {:ok, state0} = Aggregator.init(node)

    {:ok, state1, actions1} =
      Aggregator.handle_message(%{type: "result", payload: %{"candidate" => 2}}, state0, %{})

    refute Enum.any?(actions1, &match?({:complete_job, _}, &1))

    {:ok, state2, actions2} =
      Aggregator.handle_message(%{type: "result", payload: %{"candidate" => 3}}, state1, %{})

    refute Enum.any?(actions2, &match?({:complete_job, _}, &1))

    {:ok, _state3, actions3} =
      Aggregator.handle_message(%{type: "result", payload: %{"candidate" => 5}}, state2, %{})

    assert {:complete_job, result} = Enum.find(actions3, &match?({:complete_job, _}, &1))
    assert length(result["messages"]) == 3
    assert result["last_message"] == %{"candidate" => 5}
  end
end
