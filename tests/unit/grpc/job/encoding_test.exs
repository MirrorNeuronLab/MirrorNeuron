defmodule MirrorNeuron.Grpc.Handlers.Job.EncodingTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Grpc.Handlers.Job.Encoding

  test "response metadata follows the durable revision and pagination cursor" do
    value = %{"items" => [], "revision" => 7, "next_page_token" => "cursor"}
    response = Encoding.respond({:ok, value})
    assert response.version == 1
    assert response.revision == 7
    assert response.next_page_token == "cursor"
    assert Jason.decode!(response.result_json) == value
  end

  test "scalar and unversioned results retain default response metadata" do
    for value <- [nil, false, "accepted", %{}] do
      response = Encoding.response(value)
      assert response.revision == 0
      assert response.next_page_token == ""
      assert Jason.decode!(response.result_json) == value
    end
  end

  test "definition command responses never embed executable manifests" do
    response =
      Encoding.respond_definition(
        {:ok,
         %{
           "job_id" => "job",
           "revision" => 3,
           "manifest" => %{"secret" => "private"},
           "bundle" => %{"manifest" => %{"secret" => "private"}}
         }},
        :summary
      )

    result = Jason.decode!(response.result_json)
    assert result["job_id"] == "job"
    refute response.result_json =~ "private"
    refute Map.has_key?(result, "manifest")
  end

  test "failed runtime operations retain semantic gRPC status" do
    error = assert_raise GRPC.RPCError, fn -> Encoding.respond({:error, :revision_mismatch}) end
    assert error.status == GRPC.Status.failed_precondition()
  end
end
