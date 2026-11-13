defmodule MirrorNeuron.ModelServicesTest.GatewayTest do
  use MirrorNeuron.ModelServicesCase, async: false

  alias MirrorNeuron.ModelServices

  test "LiteLLM gateway sync forwards to node-local SDK gRPC service" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_sync_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_sync_client, fn target,
                                                                           request,
                                                                           timeout ->
        send(parent, {:sync_forwarded, target, Jason.decode!(request.resource_json), timeout})

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{"status" => "running"}),
           version: 1
         }}
      end)

      assert {:ok, %{"status" => "running"}} =
               ModelServices.sync_litellm_gateway(%{"runtime_endpoints" => %{}}, 4321)

      assert_receive {:sync_forwarded, "127.0.0.1:55052", %{"runtime_endpoints" => %{}}, 4321}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_sync_client, previous_client)
    end
  end

  test "LiteLLM gateway route removal forwards to node-local SDK gRPC service" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    previous_client =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_remove_gateway_route_client)

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_remove_gateway_route_client, fn target,
                                                                                           request,
                                                                                           timeout ->
        send(parent, {:remove_forwarded, target, Jason.decode!(request.resource_json), timeout})

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{"status" => "removed"}),
           version: 1
         }}
      end)

      assert {:ok, %{"status" => "removed"}} =
               ModelServices.remove_litellm_gateway_route(
                 %{"model" => "nemotron-3.5-bolt-e4b:q4_k_m"},
                 4321
               )

      assert_receive {:remove_forwarded, "127.0.0.1:55052",
                      %{"model" => "nemotron-3.5-bolt-e4b:q4_k_m"}, 4321}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_remove_gateway_route_client, previous_client)
    end
  end

  test "LiteLLM gateway commands refuse requests sent to the wrong node" do
    assert {:error, sync_message} =
             ModelServices.sync_litellm_gateway_on_node("mirror_neuron@remote", %{
               "runtime_endpoints" => %{}
             })

    assert sync_message =~ "matching gRPC command"

    assert {:error, remove_message} =
             ModelServices.remove_litellm_gateway_route_on_node("mirror_neuron@remote", %{
               "model" => "nemotron-3.5-bolt-e4b:q4_k_m"
             })

    assert remove_message =~ "matching gRPC command"
  end
end
