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
      {%{}, "gemma4:e2b"},
      {%{"model" => "default"}, "gemma4:e2b"},
      {%{"purpose" => "context_engine"}, "hf.co/homerquan/mn-context-engine-model-v-Q4_K_M"},
      {%{"purpose" => "knowledge_rag"},
       "huggingface.co/jinaai/jina-embeddings-v5-text-small-retrieval:Q4_K_M"}
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
               "model" => "gemma4:e2b"
             })

    assert message =~ "send PrepareRuntimeModel gRPC to the target node runtime"
  end

  test "DockerWorker preparation and cleanup forward to the node-local SDK gRPC service" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    previous_prepare_client =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_prepare_docker_worker_client)

    previous_cleanup_client =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_cleanup_docker_worker_client)

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    prepare_request = %Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest{
      manifest_json: "{\"nodes\":[]}",
      payloads: %{"Dockerfile" => "FROM scratch"},
      submission_id: "submission-1",
      node_name: "mirror_neuron@spark",
      version: 1
    }

    cleanup_request = %Mirrorneuron.Cluster.V1.CleanupDockerWorkerRequest{
      submission_id: "submission-1",
      job_id: "job-1",
      version: 1
    }

    try do
      Application.put_env(
        :mirror_neuron,
        :native_sdk_grpc_prepare_docker_worker_client,
        fn target, request, timeout ->
          send(parent, {:docker_prepare_forwarded, target, request, timeout})

          {:ok,
           %Mirrorneuron.Cluster.V1.PrepareDockerWorkerResponse{
             result_json: "{\"prepared\":true}",
             version: 1
           }}
        end
      )

      Application.put_env(
        :mirror_neuron,
        :native_sdk_grpc_cleanup_docker_worker_client,
        fn target, request, timeout ->
          send(parent, {:docker_cleanup_forwarded, target, request, timeout})

          {:ok,
           %Mirrorneuron.Cluster.V1.CleanupDockerWorkerResponse{
             result_json: "{\"removed\":1}",
             version: 1
           }}
        end
      )

      assert {:ok, %Mirrorneuron.Cluster.V1.PrepareDockerWorkerResponse{result_json: result}} =
               ModelServices.prepare_docker_worker(prepare_request, 1234)

      assert result == "{\"prepared\":true}"
      assert_receive {:docker_prepare_forwarded, "127.0.0.1:55052", ^prepare_request, 1234}

      assert {:ok,
              %Mirrorneuron.Cluster.V1.CleanupDockerWorkerResponse{result_json: cleanup_result}} =
               ModelServices.cleanup_docker_worker(cleanup_request, 4321)

      assert cleanup_result == "{\"removed\":1}"
      assert_receive {:docker_cleanup_forwarded, "127.0.0.1:55052", ^cleanup_request, 4321}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_prepare_docker_worker_client, previous_prepare_client)
      restore_app_env(:native_sdk_grpc_cleanup_docker_worker_client, previous_cleanup_client)
    end
  end

  test "DockerWorker preparation refuses requests sent to the wrong node" do
    request = %Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest{}

    assert {:error, message} =
             ModelServices.prepare_docker_worker_on_node("mirror_neuron@remote", request)

    assert message =~ "send PrepareDockerWorker gRPC to the target node native SDK service"
  end

  test "DockerCompose prepare, status, and cleanup use the node-local native SDK" do
    previous = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    previous_prepare =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_prepare_docker_compose_client)

    previous_status =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_docker_compose_status_client)

    previous_cleanup =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_cleanup_docker_compose_client)

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    prepare = %Mirrorneuron.Cluster.V1.PrepareDockerComposeRequest{
      manifest_json: "{\"nodes\":[]}",
      submission_id: "compose-1",
      version: 1
    }

    status = %Mirrorneuron.Cluster.V1.DockerComposeStatusRequest{
      project_json: "{\"project_name\":\"mn-compose-1\"}",
      version: 1
    }

    cleanup = %Mirrorneuron.Cluster.V1.CleanupDockerComposeRequest{
      projects_json: ["{\"project_name\":\"mn-compose-1\"}"],
      version: 1
    }

    try do
      Application.put_env(
        :mirror_neuron,
        :native_sdk_grpc_prepare_docker_compose_client,
        fn target, request, timeout ->
          send(parent, {:compose_prepare, target, request, timeout})

          {:ok,
           %Mirrorneuron.Cluster.V1.PrepareDockerComposeResponse{result_json: "{}", version: 1}}
        end
      )

      Application.put_env(
        :mirror_neuron,
        :native_sdk_grpc_docker_compose_status_client,
        fn target, request, timeout ->
          send(parent, {:compose_status, target, request, timeout})

          {:ok,
           %Mirrorneuron.Cluster.V1.DockerComposeStatusResponse{result_json: "{}", version: 1}}
        end
      )

      Application.put_env(
        :mirror_neuron,
        :native_sdk_grpc_cleanup_docker_compose_client,
        fn target, request, timeout ->
          send(parent, {:compose_cleanup, target, request, timeout})

          {:ok,
           %Mirrorneuron.Cluster.V1.CleanupDockerComposeResponse{result_json: "{}", version: 1}}
        end
      )

      assert {:ok, _} = ModelServices.prepare_docker_compose(prepare, 1234)
      assert {:ok, _} = ModelServices.docker_compose_status(status, 1234)
      assert {:ok, _} = ModelServices.cleanup_docker_compose(cleanup, 1234)
      assert_receive {:compose_prepare, "127.0.0.1:55052", ^prepare, 1234}
      assert_receive {:compose_status, "127.0.0.1:55052", ^status, 1234}
      assert_receive {:compose_cleanup, "127.0.0.1:55052", ^cleanup, 1234}
    after
      restore_env("MN_NATIVE_SDK_GRPC_TARGET", previous)
      restore_app_env(:native_sdk_grpc_prepare_docker_compose_client, previous_prepare)
      restore_app_env(:native_sdk_grpc_docker_compose_status_client, previous_status)
      restore_app_env(:native_sdk_grpc_cleanup_docker_compose_client, previous_cleanup)
    end
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
