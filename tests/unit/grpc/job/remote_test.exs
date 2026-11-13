defmodule MirrorNeuron.Grpc.Handlers.Job.RemoteTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Grpc.Handlers.Job.Remote

  test "a second federation hop is rejected before any connection attempt" do
    error =
      assert_raise GRPC.RPCError, fn ->
        Remote.forward_call("unused@unreachable", :get_job, %{}, %{
          metadata: %{"x-mn-federation-hop" => "1"}
        })
      end

    assert error.status == GRPC.Status.failed_precondition()
    assert error.message =~ "MN_FEDERATION_LOOP"
  end
end
