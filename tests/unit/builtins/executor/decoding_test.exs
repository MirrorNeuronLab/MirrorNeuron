defmodule MirrorNeuron.Builtins.Executor.DecodingTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Builtins.Executor.Decoding

  test "malformed action containers return a typed nonretryable error" do
    for key <- ["events", "emit_messages"], invalid <- [nil, %{}, "invalid", 12] do
      assert {:error, %{"retryable" => false}} =
               Decoding.decode_structured_result(%{"structured_result" => %{key => invalid}})
    end
  end

  test "invalid binary message encodings fail before action execution" do
    for value <- ["not-base64!", %{}, 42] do
      payload = %{"emit_messages" => [%{"type" => "output", "body_base64" => value}]}

      assert {:error, %{"retryable" => false}} =
               Decoding.decode_structured_result(%{"structured_result" => payload})
    end
  end

  test "retired completion flags are rejected even alongside a valid new key" do
    assert {:error, %{"unsupported_keys" => ["complete_job"]}} =
             Decoding.decode_structured_result(%{
               "structured_result" => %{"complete_job" => true, "complete_run" => true}
             })
  end

  test "ordinary output remains ordinary and valid structured emissions remain unchanged" do
    assert :ignore = Decoding.decode_structured_result(%{"stdout" => "plain output"})

    payload = %{
      "emit_messages" => [%{"type" => "output", "body_base64" => Base.encode64(<<0, 255>>)}]
    }

    assert {:ok, ^payload} = Decoding.decode_structured_result(%{"structured_result" => payload})
  end
end
