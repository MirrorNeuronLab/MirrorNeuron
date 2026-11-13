defmodule MirrorNeuron.Runtime.JobResponse.FallbackTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.JobResponse.Fallback

  test "fallback answers bound multilingual citations and omit private evidence fields" do
    attrs = %{
      "request_id" => "request-a",
      "context" => %{
        "profile" => %{"name" => "Example", "mission" => "Summarize evidence"},
        "state" => "paused",
        "evidence" =>
          for n <- 1..100 do
            %{
              "record_id" => "record-#{n}",
              "summary" => String.duplicate("界", 1_000),
              "private" => "secret"
            }
          end
      }
    }

    answer = Fallback.fallback(attrs, %{"job_id" => "job-a"}, "degraded", "native_unavailable")
    encoded = Jason.encode!(answer)

    assert byte_size(encoded) <= 64 * 1_024
    assert length(answer["citations"]) <= 20
    assert answer["request_id"] == "request-a"
    assert answer["model"] == %{"used" => false, "fallback" => true}
    assert answer["conversation_persisted"] == false
    refute encoded =~ "secret"
  end

  test "bounded-agent fallback reports a completed turn with no effects" do
    definition = %{
      "job_id" => "job-a",
      "manifest" => %{"response_service" => %{"agent" => %{"kind" => "bounded_mcp"}}}
    }

    answer = Fallback.fallback(%{}, definition, "failed", "response_service_unavailable")
    assert answer["schema_version"] == "mn.mcp.job_answer.v3"
    assert answer["turn"]["state"] == "completed"
    assert answer["effects"] == []
    assert is_binary(answer["turn"]["turn_id"])
  end
end
