defmodule MirrorNeuron.Grpc.ClusterServerTest.ModelsTest do
  use MirrorNeuron.GrpcClusterCase, async: false

  @identity_token_env "MN_GRPC_AUTH_TOKEN"

  alias MirrorNeuron.Grpc.ClusterServer
  alias Mirrorneuron.Cluster.V1.SetResourceRequest

  test "network-only mode forwards runtime model preparation to node-local SDK" do
    System.put_env(@identity_token_env, "model-prepare-test")
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "mn-native-sdk-grpc:55052")
    parent = self()
    self_node = to_string(Node.self())

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn target, request, timeout ->
        send(
          parent,
          {:native_prepare_forwarded, target, Jason.decode!(request.resource_json), timeout}
        )

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json:
             Jason.encode!(%{
               "status" => "installed",
               "endpoint" => %{
                 "api_base" => "http://host.docker.internal:12434/engines/v1",
                 "node" => "mirror_neuron@test",
                 "source" => "sdk_native_runtime_service"
               }
             }),
           version: 1
         }}
      end)

      response =
        ClusterServer.prepare_runtime_model(
          %SetResourceRequest{
            version: 1,
            resource_json:
              Jason.encode!(%{
                "node" => self_node,
                "model" => "nemotron3",
                "backend" => "llama.cpp",
                "source" => "mn-python-sdk"
              })
          },
          identity_stream("model-prepare-test")
        )

      assert %Mirrorneuron.Cluster.V1.SetResourceResponse{} = response

      assert %{"status" => "installed", "endpoint" => %{"source" => "sdk_native_runtime_service"}} =
               Jason.decode!(response.resource_json)

      assert_receive {:native_prepare_forwarded, "mn-native-sdk-grpc:55052",
                      %{
                        "node" => ^self_node,
                        "model" => "nemotron3",
                        "backend" => "llama.cpp",
                        "source" => "mn-python-sdk"
                      }, _timeout}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target)
      restore_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "prepare runtime model command forwards normalized default payload" do
    System.put_env(@identity_token_env, "model-prepare-test")
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "mn-native-sdk-grpc:55052")
    parent = self()

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn target, request, timeout ->
        send(
          parent,
          {:native_prepare_forwarded, target, Jason.decode!(request.resource_json), timeout}
        )

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{"status" => "installed"}),
           version: 1
         }}
      end)

      response =
        ClusterServer.prepare_runtime_model(
          %SetResourceRequest{
            version: 1,
            resource_json: Jason.encode!(%{"purpose" => "knowledge_rag"})
          },
          identity_stream("model-prepare-test")
        )

      assert %Mirrorneuron.Cluster.V1.SetResourceResponse{} = response
      assert %{"status" => "installed"} = Jason.decode!(response.resource_json)

      assert_receive {:native_prepare_forwarded, "mn-native-sdk-grpc:55052",
                      %{
                        "purpose" => "knowledge_rag",
                        "model" =>
                          "huggingface.co/zenmagnets/Nemotron-3-Embed-1B-Q4_K_M-GGUF:Q4_K_M",
                        "runtime_model" =>
                          "huggingface.co/zenmagnets/Nemotron-3-Embed-1B-Q4_K_M-GGUF:Q4_K_M"
                      }, _timeout}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target)
      restore_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "prepare runtime model command preserves native model preconditions" do
    System.put_env(@identity_token_env, "model-prepare-test")
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "mn-native-sdk-grpc:55052")

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn _target,
                                                                      _request,
                                                                      _timeout ->
        {:error,
         GRPC.RPCError.exception(
           :failed_precondition,
           "nemotron3 requires at least 48GB unified memory on Apple Silicon."
         )}
      end)

      error =
        assert_raise GRPC.RPCError, fn ->
          ClusterServer.prepare_runtime_model(
            %SetResourceRequest{
              version: 1,
              resource_json: Jason.encode!(%{"model" => "nemotron3"})
            },
            identity_stream("model-prepare-test")
          )
        end

      assert error.status == GRPC.Status.failed_precondition()
      assert error.message == "nemotron3 requires at least 48GB unified memory on Apple Silicon."
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target)
      restore_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "model preparation rejects missing credentials before dispatch" do
    System.put_env(@identity_token_env, "model-prepare-test")

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.prepare_runtime_model(
          %SetResourceRequest{version: 1, resource_json: "{}"},
          nil
        )
      end

    assert error.status == GRPC.Status.unauthenticated()
  end
end
