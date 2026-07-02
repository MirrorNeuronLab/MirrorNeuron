defmodule MirrorNeuron.ModelServicesTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.ModelServices

  test "explicit model service JSON advertises model runner services" do
    env = %{
      "MN_MODEL_SERVICES_JSON" =>
        Jason.encode!(%{
          "services" => [
            %{
              "name" => "docker-model-runner",
              "tags" => ["model:gemma4:e2b", "model-id:gemma4:e2b"],
              "meta" => %{
                "model_id" => "gemma4:e2b",
                "model" => "ai/gemma4:E2B",
                "api_model" => "ai/gemma4:E2B"
              }
            }
          ]
        }),
      "MN_DOCKER_MODEL_RUNNER_API_BASE" => "http://model-runner.docker.internal/engines/v1"
    }

    [service] = ModelServices.service_instances_for_env(env, "node@lab")

    assert service["name"] == "docker-model-runner"
    assert service["node"] == "node@lab"
    assert service["status"] == "passing"
    assert service["meta"]["model_id"] == "gemma4:e2b"
    assert "model:gemma4:e2b" in service["tags"]

    assert [%{"url" => "http://model-runner.docker.internal/engines/v1/models"}] =
             service["checks"]
  end

  test "symbolic model refs no longer expand inside core" do
    assert ModelServices.service_instances_for_models(["gemma4:e2b"], "node@lab") == []
  end

  test "runtime model preparation is rejected when native SDK target is missing" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    System.delete_env("MN_NATIVE_SDK_GRPC_TARGET")

    try do
      assert {:error, message} = ModelServices.prepare_runtime_model(%{"model" => "gemma4:e2b"})
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
               ModelServices.prepare_runtime_model(%{"model" => "gemma4:e2b"}, 1234)

      assert_receive {:prepare_forwarded, "127.0.0.1:55052", %{"model" => "gemma4:e2b"}, 1234}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_client, previous_client)
    end
  end

  test "runtime model preparation refuses requests sent to the wrong node" do
    assert {:error, message} =
             ModelServices.prepare_runtime_model_on_node("mirror_neuron@remote", %{
               "model" => "gemma4:e2b"
             })

    assert message =~ "send PrepareRuntimeModel gRPC to the target node runtime"
  end

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
               ModelServices.remove_litellm_gateway_route(%{"model" => "gemma4:e2b"}, 4321)

      assert_receive {:remove_forwarded, "127.0.0.1:55052", %{"model" => "gemma4:e2b"}, 4321}
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
               "model" => "gemma4:e2b"
             })

    assert remove_message =~ "matching gRPC command"
  end

  test "model services use advertised host identity when docker hostname differs" do
    env = %{"MN_NETWORK_ADVERTISE_HOST" => "192.168.4.173"}

    assert ModelServices.advertised_node_name(:"mirror_neuron@mn-c13e508c", env) ==
             "mirror_neuron@192.168.4.173"
  end

  test "explicit model service node identity overrides advertised host" do
    env = %{
      "MN_MODEL_SERVICE_NODE_NAME" => "mirror_neuron@gpu-node",
      "MN_NETWORK_ADVERTISE_HOST" => "192.168.4.173"
    }

    assert ModelServices.advertised_node_name(:"mirror_neuron@mn-c13e508c", env) ==
             "mirror_neuron@gpu-node"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
