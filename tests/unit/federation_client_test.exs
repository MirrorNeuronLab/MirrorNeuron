defmodule MirrorNeuron.Cluster.FederationClientTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Cluster.FederationClient

  test "application errors do not mark a federated peer unavailable" do
    refute FederationClient.availability_failure?(
             GRPC.RPCError.exception(
               status: GRPC.Status.internal(),
               message: "not_found"
             )
           )

    refute FederationClient.availability_failure?(
             GRPC.RPCError.exception(
               status: GRPC.Status.failed_precondition(),
               message: "invalid state"
             )
           )
  end

  test "transport and authentication failures mark a federated peer unavailable" do
    for status <- [
          GRPC.Status.deadline_exceeded(),
          GRPC.Status.unauthenticated(),
          GRPC.Status.unavailable()
        ] do
      assert FederationClient.availability_failure?(
               GRPC.RPCError.exception(status: status, message: "peer unavailable")
             )
    end

    assert FederationClient.availability_failure?(:econnrefused)
  end
end
