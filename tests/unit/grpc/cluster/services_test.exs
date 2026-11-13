defmodule MirrorNeuron.Grpc.ClusterServerTest.ServicesTest do
  use MirrorNeuron.GrpcClusterCase, async: false

  @identity_token_env "MN_GRPC_AUTH_TOKEN"

  alias MirrorNeuron.Grpc.ClusterServer
  alias Mirrorneuron.Cluster.V1.CheckServicesRequest

  test "check services RPC runs generic direct checks and returns a validation report" do
    System.put_env(@identity_token_env, "operator-token")
    port = start_tcp_server()

    response =
      ClusterServer.check_services(
        %CheckServicesRequest{
          version: 1,
          services_json:
            Jason.encode!([
              %{
                "name" => "agent-api",
                "address" => "127.0.0.1",
                "port" => port,
                "checks" => [%{"name" => "tcp", "type" => "tcp", "timeout_ms" => 1_000}]
              }
            ])
        },
        %{headers: %{"authorization" => "Bearer operator-token"}}
      )

    assert %{"ok" => true, "results" => [%{"name" => "agent-api"}]} =
             Jason.decode!(response.result_json)
  end
end
