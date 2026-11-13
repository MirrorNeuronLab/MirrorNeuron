defmodule MirrorNeuron.Runtime.JobCoordinator.MessagesTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.JobCoordinator.Messages

  defp state(opts \\ []) do
    %{job_id: "run-a", manifest: %{contract: %{}}, opts: opts}
  end

  test "external envelopes preserve message identity and carry the current attempt fence" do
    original =
      Message.new("run-a", "external", "worker", "work", %{"value" => 3},
        message_id: "stable-id",
        correlation_id: "stable-correlation",
        headers: %{"mn.attempt_epoch" => 2, "trace" => "trace-a"}
      )

    result =
      Messages.build_external_message(state(job_lease: %{"epoch" => 7}), "worker", original)

    assert Message.id(result) == "stable-id"
    assert Message.correlation_id(result) == "stable-correlation"
    assert Message.body(result) == %{"value" => 3}
    assert Message.headers(result) == %{"mn.attempt_epoch" => 7, "trace" => "trace-a"}
  end

  test "raw input gets a command envelope for the requested worker" do
    result = Messages.build_external_message(state(), "worker", %{"value" => 3})

    assert Message.job_id(result) == "run-a"
    assert Message.from(result) == "external"
    assert Message.to(result) == "worker"
    assert Message.type(result) == "command"
    assert Message.class(result) == "command"
    assert Message.body(result) == %{"value" => 3}
    assert is_binary(Message.id(result))
  end

  test "typed input retains its payload for atom and string keys" do
    for input <- [%{type: "update", payload: [1, 2]}, %{"type" => "update", "payload" => [1, 2]}] do
      result = Messages.build_external_message(state(), "worker", input)
      assert Message.type(result) == "update"
      assert Message.body(result) == [1, 2]
    end
  end

  test "a missing attempt lease does not invent a fence" do
    message = Message.new("run-a", "external", "worker", "work", %{})
    assert Messages.put_attempt_epoch(message, state()) == message
  end
end
