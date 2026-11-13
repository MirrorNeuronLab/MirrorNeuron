defmodule MirrorNeuron.Runtime.JobResponse.ValidationTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.JobResponse
  alias MirrorNeuron.Runtime.JobResponse.Validation

  @conversation "12345678-1234-4234-8234-123456789abc"

  test "local and forwarded query entry points reject invalid requests before job lookup" do
    for {attrs, reason} <- [
          {%{}, :question_required},
          {%{"question" => "  "}, :question_required},
          {%{"question" => String.duplicate("x", 8_001)}, :question_too_long},
          {%{"question" => "status?", "request_id" => 12}, :invalid_request_id},
          {%{"question" => "status?", "context" => []}, :invalid_job_context}
        ] do
      assert {:error, ^reason} = JobResponse.query("invalid-query-job", attrs)
      assert {:error, ^reason} = JobResponse.query_local("invalid-query-job", attrs)
    end
  end

  test "turn IDs have the same validation at both public and local boundaries" do
    for id <- [nil, "", "not-a-uuid", @conversation <> "\n"] do
      assert {:error, :invalid_turn_id} = JobResponse.get_turn("invalid-turn-job", id)
      assert {:error, :invalid_turn_id} = JobResponse.get_turn_local("invalid-turn-job", id)
    end
  end

  test "a conversation ID must match the entire UUID, including its end" do
    assert :ok =
             Validation.validate_query(%{
               "question" => "status?",
               "conversation_id" => @conversation
             })

    for id <- [@conversation <> "\n", " " <> @conversation, @conversation <> "suffix"] do
      assert {:error, :invalid_conversation_id} =
               Validation.validate_query(%{"question" => "status?", "conversation_id" => id})
    end
  end

  test "context limits count encoded bytes and reject unencodable values" do
    assert {:error, :job_context_too_large} =
             Validation.validate_query(%{
               "question" => "status?",
               "context" => %{"text" => String.duplicate("界", 90_000)}
             })

    assert {:error, :job_context_too_large} =
             Validation.validate_query(%{
               "question" => "status?",
               "context" => %{"process" => self()}
             })
  end
end
