defmodule MirrorNeuron.StepBoundariesTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.{StepJoin, StepSink, StepSource}
  alias MirrorNeuron.Message

  test "step source joins upstream outputs and dispatches mapped input once" do
    node = %{
      config: %{
        "step_id" => "score",
        "required_upstreams" => ["evidence", "research"],
        "fields" => %{
          "company" => %{"$ref" => "run_input", "path" => ["company"]},
          "claims" => %{
            "$ref" => "upstream",
            "step_id" => "evidence",
            "path" => ["claims"]
          }
        },
        "output_message_type" => "score__start_completed"
      }
    }

    {:ok, state0} = StepSource.init(node)

    evidence =
      message(
        "evidence",
        "score__start",
        "evidence_completed",
        %{
          "step_id" => "evidence",
          "outputs" => %{"claims" => ["one"]},
          "_mn_step" => %{"run_inputs" => %{"company" => "Acme"}}
        },
        "evidence-message"
      )

    {:ok, state1, waiting} = StepSource.handle_message(evidence, state0, %{})
    assert Enum.any?(waiting, &match?({:event, :step_source_waiting, _}, &1))

    research =
      message(
        "research",
        "score__start",
        "research_completed",
        %{"step_id" => "research", "outputs" => %{"sources" => 2}},
        "research-message"
      )

    {:ok, state2, actions} = StepSource.handle_message(research, state1, %{})

    assert {:emit, "score__start_completed", dispatched, _opts} =
             Enum.find(actions, &match?({:emit, "score__start_completed", _, _}, &1))

    assert dispatched["outputs"] == %{"company" => "Acme", "claims" => ["one"]}
    refute Map.has_key?(dispatched["_mn_step"], "run_inputs")
    refute Map.has_key?(dispatched["_mn_step"], "step_input")

    {:ok, replayed, replay_actions} = StepSource.handle_message(research, state2, %{})
    assert replayed == state2
    assert Enum.any?(replay_actions, &match?({:event, :step_source_duplicate_ignored, _}, &1))
  end

  @tag :tmp_dir
  test "root step source stages immutable run inputs outside step metadata", %{tmp_dir: tmp_dir} do
    submission = Path.join(tmp_dir, "submission")

    node = %{
      config: %{
        "step_id" => "root",
        "required_upstreams" => [],
        "environment" => %{
          "MN_JOB_SHARED_STORAGE_ROOT" => submission,
          "MN_STORAGE_SUBMISSION_ID" => "submission-1"
        },
        "fields" => %{
          "company" => %{"$ref" => "run_input", "path" => ["company"]}
        },
        "output_message_type" => "root_started"
      }
    }

    {:ok, state} = StepSource.init(node)

    {:ok, _state, actions} =
      StepSource.handle_message(
        message(
          "runtime",
          "root__start",
          "init",
          %{"args" => [], "kwargs" => %{"company" => "Acme"}},
          "root-message"
        ),
        state,
        %{job_id: "job-1", workflow: %{"run_id" => "run-1"}}
      )

    assert {:emit, "root_started", result, _opts} =
             Enum.find(actions, &match?({:emit, "root_started", _, _}, &1))

    assert result["outputs"] == %{"company" => "Acme"}
    refute Map.has_key?(result["_mn_step"], "run_inputs")
    assert result["_mn_step"]["run_inputs_ref"]["kind"] == "run_inputs"

    assert File.regular?(
             Path.join(submission, result["_mn_step"]["run_inputs_ref"]["relative_path"])
           )
  end

  test "named join waits for every required agent output" do
    node = %{
      config: %{
        "expected_sources" => ["research_a", "research_b"],
        "output_keys" => %{"research_a" => "identity", "research_b" => "funding"},
        "output_message_type" => "research_joined"
      }
    }

    {:ok, state0} = StepJoin.init(node)
    context = %{node: %{node_id: "research_join"}}

    {:ok, state1, waiting} =
      StepJoin.handle_message(
        message(
          "research_a",
          "research_join",
          "a_completed",
          %{"outputs" => %{"name" => "Acme"}, "_mn_step" => %{"run_inputs" => %{}}},
          "a-message"
        ),
        state0,
        context
      )

    assert Enum.any?(waiting, &match?({:event, :step_join_waiting, _}, &1))

    {:ok, _state2, actions} =
      StepJoin.handle_message(
        message(
          "research_b",
          "research_join",
          "b_completed",
          %{"outputs" => %{"round" => "seed"}},
          "b-message"
        ),
        state1,
        context
      )

    assert {:emit, "research_joined", result, _opts} =
             Enum.find(actions, &match?({:emit, "research_joined", _, _}, &1))

    assert result["outputs"] == %{
             "identity" => %{"name" => "Acme"},
             "funding" => %{"round" => "seed"}
           }
  end

  test "fallback join dispatches only the first exhausted branch" do
    node = %{
      config: %{
        "completion_mode" => "first",
        "passthrough" => true,
        "output_message_type" => "fallback_started"
      }
    }

    {:ok, state0} = StepJoin.init(node)

    failed = %{
      "outputs" => %{"fallback_used" => true},
      "_mn_step" => %{"attempt_id" => "attempt-1"}
    }

    {:ok, state1, actions} =
      StepJoin.handle_message(
        message("primary_a", "fallback", "primary_failed", failed, "failed-a"),
        state0,
        %{}
      )

    assert {:emit, "fallback_started", ^failed, _opts} =
             Enum.find(actions, &match?({:emit, "fallback_started", _, _}, &1))

    {:ok, state2, replay_actions} =
      StepJoin.handle_message(
        message("primary_b", "fallback", "primary_failed", failed, "failed-b"),
        state1,
        %{}
      )

    assert state2 == state1
    assert Enum.any?(replay_actions, &match?({:event, :step_join_duplicate_ignored, _}, &1))
  end

  test "only step sink emits logical output and completes the step" do
    node = %{
      config: %{
        "step_id" => "prepare",
        "fields" => %{"company_evidence" => %{"$ref" => "flow_output"}},
        "output_message_type" => "prepare_completed"
      }
    }

    {:ok, state0} = StepSink.init(node)

    {:ok, state1, actions} =
      StepSink.handle_message(
        message(
          "prepare__normalize",
          "prepare__end",
          "normalize_completed",
          %{
            "outputs" => %{"normalized" => true},
            "_mn_step" => %{"run_inputs" => %{"company" => "Acme"}}
          },
          "normalize-message"
        ),
        state0,
        %{}
      )

    assert {:emit, "prepare_completed", result, _opts} =
             Enum.find(actions, &match?({:emit, "prepare_completed", _, _}, &1))

    assert result["outputs"] == %{"company_evidence" => %{"normalized" => true}}

    assert {:complete_step, ^result} =
             Enum.find(actions, &match?({:complete_step, _}, &1))

    {:ok, replayed, replay_actions} =
      StepSink.handle_message(
        message("prepare__normalize", "prepare__end", "normalize_completed", %{}, "other"),
        state1,
        %{}
      )

    assert replayed == state1
    assert Enum.any?(replay_actions, &match?({:event, :step_sink_duplicate_ignored, _}, &1))
  end

  test "boundary state resets when a new logical step attempt arrives" do
    node = %{
      config: %{
        "step_id" => "prepare",
        "fields" => %{"result" => %{"$ref" => "flow_output"}},
        "output_message_type" => "prepare_completed"
      }
    }

    {:ok, state0} = StepSink.init(node)

    first =
      message(
        "worker",
        "prepare__end",
        "done",
        %{"outputs" => %{"round" => 1}, "_mn_step" => %{"attempt_id" => "attempt-1"}},
        "same-message"
      )

    second =
      message(
        "worker",
        "prepare__end",
        "done",
        %{"outputs" => %{"round" => 2}, "_mn_step" => %{"attempt_id" => "attempt-2"}},
        "same-message"
      )

    {:ok, state1, first_actions} = StepSink.handle_message(first, state0, %{})
    assert Enum.any?(first_actions, &match?({:complete_step, _}, &1))

    {:ok, _state2, second_actions} = StepSink.handle_message(second, state1, %{})
    assert Enum.any?(second_actions, &match?({:complete_step, _}, &1))
  end

  defp message(from, to, type, body, message_id) do
    Message.new("job", from, to, type, body,
      message_id: message_id,
      correlation_id: "correlation"
    )
  end
end
