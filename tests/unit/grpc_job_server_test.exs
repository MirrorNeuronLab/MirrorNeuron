defmodule MirrorNeuron.Grpc.JobServerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.JobServer
  alias Mirrorneuron.Job.V1.ClearJobsRequest

  setup do
    old_token = System.get_env("MIRROR_NEURON_GRPC_ADMIN_TOKEN")
    System.delete_env("MIRROR_NEURON_GRPC_ADMIN_TOKEN")

    on_exit(fn ->
      if is_nil(old_token) do
        System.delete_env("MIRROR_NEURON_GRPC_ADMIN_TOKEN")
      else
        System.put_env("MIRROR_NEURON_GRPC_ADMIN_TOKEN", old_token)
      end
    end)
  end

  test "clear_jobs rejects unauthenticated requests before deleting jobs" do
    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.clear_jobs(%ClearJobsRequest{}, nil)
      end

    assert Exception.message(error) =~ "ClearJobs requires MIRROR_NEURON_GRPC_ADMIN_TOKEN"
  end
end
