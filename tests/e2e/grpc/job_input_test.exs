defmodule MirrorNeuron.Grpc.Handlers.Job.InputBoundaryTest do
  use MirrorNeuron.RedisStoreCase, async: false
  alias MirrorNeuron.Grpc.Handlers.Job
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.LiveInput
  alias Mirrorneuron.Job.V1.SendRunInputRequest

  setup do
    run_id = "grpc-input-#{System.unique_integer([:positive])}"
    assert {:ok, _} = RedisStore.persist_job(run_id, %{"job_id" => run_id, "status" => "running"})
    %{run_id: run_id}
  end

  test "malformed input JSON is rejected before submission", %{run_id: run_id} do
    for payload <- ["[", "[]", "42"] do
      error =
        assert_raise GRPC.RPCError, fn ->
          Job.send_run_input(
            %SendRunInputRequest{run_id: run_id, input_id: "input", payload_json: payload},
            nil
          )
        end

      assert error.status == GRPC.Status.invalid_argument()
    end
  end

  test "oversized input is rejected before decoding or queue admission", %{run_id: run_id} do
    error =
      assert_raise GRPC.RPCError, fn ->
        Job.send_run_input(
          %SendRunInputRequest{
            run_id: run_id,
            input_id: "input",
            payload_json: String.duplicate("x", LiveInput.max_payload_bytes() + 1)
          },
          nil
        )
      end

    assert error.status == GRPC.Status.invalid_argument()
    assert error.message =~ "size limit"
  end
end
