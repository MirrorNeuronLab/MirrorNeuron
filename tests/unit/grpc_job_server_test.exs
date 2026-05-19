defmodule MirrorNeuron.Grpc.JobServerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.JobServer
  alias Mirrorneuron.Job.V1.ClearJobsRequest
  @admin_token_env "MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN"

  setup do
    old_token = System.get_env(@admin_token_env)
    System.delete_env(@admin_token_env)

    on_exit(fn ->
      if is_nil(old_token) do
        System.delete_env(@admin_token_env)
      else
        System.put_env(@admin_token_env, old_token)
      end
    end)
  end

  test "clear_jobs rejects unauthenticated requests before deleting jobs" do
    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.clear_jobs(%ClearJobsRequest{}, nil)
      end

    assert Exception.message(error) =~ "ClearJobs requires #{@admin_token_env}"
  end
end
