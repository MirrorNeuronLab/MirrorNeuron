defmodule MirrorNeuron.Grpc.RuntimeControlRouteTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Grpc.RuntimeControlRoute
  alias Mirrorneuron.Runtime.V1.RuntimeRequest

  test "a registered owner supplies the endpoint and private federation credential" do
    request = %RuntimeRequest{
      version: 1,
      action: "job.ui",
      arguments_json: Jason.encode!(%{"_owner_node" => "owner@test", "job_id" => "job"})
    }

    fetch = fn "owner@test" ->
      {:ok, %{"grpc_host" => "::1", "grpc_port" => 55051, "peer_auth_token" => "private-peer"}}
    end

    {target, forwarded, metadata} = RuntimeControlRoute.resolve(request, fetch)
    assert target == "[::1]:55051"
    assert metadata["authorization"] == "Bearer private-peer"
    assert Jason.decode!(forwarded.arguments_json)["_runtime_hop"] == 1
    assert Jason.decode!(forwarded.arguments_json)["job_id"] == "job"
  end

  test "missing owners and a second forwarding hop fail closed" do
    for args <- [
          %{"_owner_node" => "missing@test"},
          %{"_owner_node" => "owner@test", "_runtime_hop" => 1}
        ] do
      request = %RuntimeRequest{version: 1, arguments_json: Jason.encode!(args)}

      assert_raise GRPC.RPCError, fn ->
        RuntimeControlRoute.resolve(request, fn _ -> :error end)
      end
    end
  end

  test "arguments cannot supply an arbitrary endpoint or credential" do
    request = %RuntimeRequest{
      version: 1,
      arguments_json:
        Jason.encode!(%{
          "_owner_node" => "http://untrusted",
          "grpc_host" => "untrusted",
          "peer_auth_token" => "untrusted"
        })
    }

    assert_raise GRPC.RPCError, fn -> RuntimeControlRoute.resolve(request, fn _ -> :error end) end

    for invalid <- ["[]", "null", "invalid"] do
      assert_raise GRPC.RPCError, fn ->
        RuntimeControlRoute.resolve(%{request | arguments_json: invalid})
      end
    end
  end
end
