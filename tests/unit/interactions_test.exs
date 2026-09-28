defmodule MirrorNeuron.Runtime.InteractionsTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.Interactions
  defp record do
    %{"id" => "review-1", "kind" => "approval", "scope" => %{"job_id" => "job-1", "execution_id" => "run-1"},
      "presentation" => %{"widget" => "confirmation", "title" => "Approve?"},
      "options" => [%{"id" => "approve", "label" => "Approve", "action" => "approve"}], "fields" => []}
  end
  test "validates explicit choices and refuses arbitrary widgets" do
    assert :ok = Interactions.validate(record())
    assert {:error, "invalid_widget"} = Interactions.validate(put_in(record(), ["presentation", "widget"], "html"))
    command = %{"command_id" => "decision-1", "expected_revision" => 1, "answer" => %{"option_id" => "approve"}}
    assert :ok = Interactions.validate_response("respond", record(), command)
    assert {:error, "invalid_option"} = Interactions.validate_response("respond", record(), put_in(command, ["answer", "option_id"], "invented"))
  end
  test "does not infer consent from a label" do
    command = %{"command_id" => "decision-1", "expected_revision" => 1, "answer" => %{"text" => "Approve"}}
    assert {:error, "invalid_option"} = Interactions.validate_response("respond", record(), command)
  end
end
