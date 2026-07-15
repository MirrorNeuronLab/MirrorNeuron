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

    refute Enum.any?(actions1, &match?({:complete_run, _}, &1))

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
    refute Enum.any?(actions2, &match?({:complete_run, _}, &1))
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

  test "completes the workflow step before emitting aggregate output" do
    node = %{
      config: %{
        "complete_on_message" => true,
        "output_message_type" => "collected"
      }
    }

    {:ok, state0} = Aggregator.init(node)

    {:ok, _state1, actions} =
      Aggregator.handle_message(
        %{type: "executor_result", payload: %{"agent_id" => "worker-1", "value" => 1}},
        state0,
        %{workflow: %{"step_id" => "join_step"}}
      )

    assert [
             {:event, :aggregator_received, _},
             {:complete_step, result},
             {:emit, "collected", emitted, _opts}
           ] =
             actions

    assert emitted == result
  end

  test "coordinates dependent crew agents and deduplicates Redis replays" do
    node = %{
      config: %{
        "crew" => %{
          "step_id" => "prepare",
          "completion_message_type" => "prepare_completed",
          "agents" => [
            %{
              "agent_id" => "extractor",
              "node_id" => "prepare__extractor",
              "needs" => [],
              "input_message_type" => "prepare__extractor_input"
            },
            %{
              "agent_id" => "normalizer",
              "node_id" => "prepare__normalizer",
              "needs" => ["extractor"],
              "input_message_type" => "prepare__normalizer_input"
            }
          ]
        }
      }
    }

    {:ok, state0} = Aggregator.init(node)

    {:ok, state1, start_actions} =
      Aggregator.handle_message(
        %{type: "upstream_completed", payload: %{"company_id" => "acme"}},
        state0,
        %{workflow: %{"step_id" => "prepare"}}
      )

    assert {:emit, "prepare__extractor_input", extractor_input} =
             Enum.find(start_actions, &match?({:emit, "prepare__extractor_input", _}, &1))

    assert extractor_input["step_input"] == %{"company_id" => "acme"}
    assert extractor_input["agent_outputs"] == %{}

    extractor_output = %{
      "agent_id" => "prepare__extractor",
      "outputs" => %{"claim_count" => 2},
      "artifacts" => [%{"path" => "artifacts/evidence.json"}]
    }

    {:ok, state2, extractor_actions} =
      Aggregator.handle_message(
        %{type: "prepare__extractor_completed", payload: extractor_output},
        state1,
        %{workflow: %{"step_id" => "prepare"}}
      )

    assert {:emit, "prepare__normalizer_input", normalizer_input} =
             Enum.find(extractor_actions, &match?({:emit, "prepare__normalizer_input", _}, &1))

    assert normalizer_input["agent_outputs"] == %{"extractor" => %{"claim_count" => 2}}
    assert normalizer_input["artifact_refs"] == [%{"path" => "artifacts/evidence.json"}]

    {:ok, replayed_state, replay_actions} =
      Aggregator.handle_message(
        %{type: "prepare__extractor_completed", payload: extractor_output},
        state2,
        %{workflow: %{"step_id" => "prepare"}}
      )

    assert replayed_state == state2
    assert [{:event, :crew_agent_duplicate_output_ignored, _}] = replay_actions

    {:ok, _state3, completed_actions} =
      Aggregator.handle_message(
        %{
          type: "prepare__normalizer_completed",
          payload: %{
            "agent_id" => "prepare__normalizer",
            "outputs" => %{"normalized" => true},
            "artifacts" => [%{"path" => "artifacts/claims.json"}]
          }
        },
        replayed_state,
        %{workflow: %{"step_id" => "prepare"}}
      )

    assert {:emit, "prepare_completed", result} =
             Enum.find(completed_actions, &match?({:emit, "prepare_completed", _}, &1))

    assert result["agent_outputs"] == %{
             "extractor" => %{"claim_count" => 2},
             "normalizer" => %{"normalized" => true}
           }

    assert {:complete_step, ^result} =
             Enum.find(completed_actions, &match?({:complete_step, _}, &1))
  end
end
