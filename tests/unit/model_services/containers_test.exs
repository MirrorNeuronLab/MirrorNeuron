defmodule MirrorNeuron.ModelServicesTest.ContainersTest do
  use MirrorNeuron.ModelServicesCase, async: false

  alias MirrorNeuron.ModelServices

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
end
