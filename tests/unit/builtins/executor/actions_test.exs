defmodule MirrorNeuron.Builtins.Executor.ActionsTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Builtins.Executor.Actions
  alias MirrorNeuron.Message

  test "novel worker event names never allocate permanent BEAM atoms" do
    type = "executor_dynamic_event_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(type) end

    assert {:ok, %{}, [{:event, ^type, %{}}]} =
             actions(%{"events" => [%{"type" => type, "payload" => %{}}]})

    assert_raise ArgumentError, fn -> String.to_existing_atom(type) end
  end

  test "known atom event names retain their existing internal representation" do
    expected = :executor_known_test_event

    assert {:ok, %{}, [{:event, ^expected, %{}}]} =
             actions(%{"events" => [%{"type" => Atom.to_string(expected), "payload" => %{}}]})
  end

  test "explicit step completion is emitted once and default completion can be disabled" do
    context = %{workflow: %{"step_id" => "step"}}

    assert Actions.implicit_workflow_step_completion_actions(
             context,
             %{},
             [{:complete_step, %{}}],
             %{}
           ) == []

    assert Actions.implicit_workflow_step_completion_actions(context, %{}, [], %{
             "workflow_complete_step" => false
           }) == []

    assert Actions.implicit_workflow_step_completion_actions(%{}, %{}, [], %{}) == []
  end

  test "typed event workers cannot silently accept ordinary stdout" do
    state = %{config: %{"block_event" => %{}}, agent_state: %{}}

    assert {:error, %{"retryable" => false}} =
             Actions.structured_actions(
               %{"stdout" => "ordinary output"},
               state,
               message(),
               %{},
               %{}
             )
  end

  defp actions(payload),
    do:
      Actions.structured_actions(
        %{"structured_result" => payload},
        %{config: %{}, agent_state: %{}},
        message(),
        %{},
        %{}
      )

  defp message, do: Message.new("job", "source", "worker", "input", %{})
end
