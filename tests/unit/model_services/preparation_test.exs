defmodule MirrorNeuron.ModelServicesTest.PreparationTest do
  use MirrorNeuron.ModelServicesCase, async: false

  alias MirrorNeuron.ModelServices

  test "runtime model preparation is rejected when native SDK target is missing" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    System.delete_env("MN_NATIVE_SDK_GRPC_TARGET")

    try do
      assert {:error, message} =
               ModelServices.prepare_runtime_model(%{"model" => "nemotron-3.5-bolt-e4b:q4_k_m"})

      assert message =~ "mn-python-sdk"
      assert message =~ "MN_NATIVE_SDK_GRPC_TARGET"
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
    end
  end

  test "runtime model preparation forwards to node-local SDK gRPC service" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn target, request, timeout ->
        send(parent, {:prepare_forwarded, target, Jason.decode!(request.resource_json), timeout})

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{"status" => "installed"}),
           version: 1
         }}
      end)

      assert {:ok, %{"status" => "installed"}} =
               ModelServices.prepare_runtime_model(
                 %{"model" => "nemotron-3.5-bolt-e4b:q4_k_m"},
                 1234
               )

      assert_receive {:prepare_forwarded, "127.0.0.1:55052",
                      %{"model" => "nemotron-3.5-bolt-e4b:q4_k_m"}, 1234}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "runtime model preparation preserves a native precondition failure" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")

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

      assert {:error, %GRPC.RPCError{} = error} =
               ModelServices.prepare_runtime_model(%{"model" => "nemotron3"}, 1234)

      assert error.status == GRPC.Status.failed_precondition()
      assert error.message == "nemotron3 requires at least 48GB unified memory on Apple Silicon."
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "runtime model preparation marks native link failures unavailable" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn _target,
                                                                      _request,
                                                                      _timeout ->
        {:error, :econnrefused}
      end)

      assert {:error, %GRPC.RPCError{} = error} =
               ModelServices.prepare_runtime_model(%{"model" => "nemotron3"}, 1234)

      assert error.status == GRPC.Status.unavailable()
      assert error.message =~ "native SDK gRPC prepare is unavailable"
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "runtime model preparation normalizes default and purpose requests before forwarding" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    cases = [
      {%{}, "nemotron-3.5-bolt-e4b:q4_k_m"},
      {%{"model" => "default"}, "nemotron-3.5-bolt-e4b:q4_k_m"},
      {%{"purpose" => "context_engine"}, "default"},
      {%{"purpose" => "knowledge_rag"},
       "huggingface.co/zenmagnets/Nemotron-3-Embed-1B-Q4_K_M-GGUF:Q4_K_M"}
    ]

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn target, request, timeout ->
        attrs = Jason.decode!(request.resource_json)
        send(parent, {:prepare_forwarded, target, attrs, timeout})

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{"status" => "installed", "model" => attrs["model"]}),
           version: 1
         }}
      end)

      for {attrs, expected_model} <- cases do
        assert {:ok, %{"status" => "installed", "model" => ^expected_model}} =
                 ModelServices.prepare_runtime_model(attrs, 1234)

        assert_receive {:prepare_forwarded, "127.0.0.1:55052",
                        %{"model" => ^expected_model, "runtime_model" => ^expected_model}, 1234}
      end
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "runtime model preparation refuses requests sent to the wrong node" do
    assert {:error, message} =
             ModelServices.prepare_runtime_model_on_node("mirror_neuron@remote", %{
               "model" => "nemotron-3.5-bolt-e4b:q4_k_m"
             })

    assert message =~ "send PrepareRuntimeModel gRPC to the target node runtime"
  end

  test "job backup Python requests never select a default model" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_client = Application.get_env(:mirror_neuron, :native_sdk_grpc_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    try do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_client, fn _, request, _ ->
        attrs = Jason.decode!(request.resource_json)
        send(parent, {:backup_python, attrs})

        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: "{\"status\":\"ready\"}",
           version: 1
         }}
      end)

      for action <- ["export_hostlocal_wheels", "inspect_hostlocal_python"] do
        assert {:ok, %{"status" => "ready"}} =
                 ModelServices.prepare_runtime_model(%{
                   "purpose" => "job_backup",
                   "action" => action
                 })

        assert_receive {:backup_python, attrs}
        refute Map.has_key?(attrs, "model")
        refute Map.has_key?(attrs, "runtime_model")
      end

      assert {:error, "unsupported job backup Python request"} =
               ModelServices.prepare_runtime_model(%{
                 "purpose" => "job_backup",
                 "action" => "pull"
               })

      refute_receive {:backup_python, _}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_client, previous_client)
    end
  end
end
