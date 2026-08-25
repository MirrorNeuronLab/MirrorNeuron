defmodule MirrorNeuron.Runtime.RunnerResourcesTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runtime.RunnerResources

  alias Mirrorneuron.Cluster.V1.{
    CleanupDockerComposeResponse,
    CleanupDockerWorkerResponse
  }

  @client_keys [
    :native_sdk_grpc_cleanup_docker_compose_client,
    :native_sdk_grpc_cleanup_docker_worker_client
  ]

  setup do
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_clients = Map.new(@client_keys, &{&1, Application.get_env(:mirror_neuron, &1)})
    parent = self()

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_cleanup_docker_worker_client,
      fn _target, request, _timeout ->
        send(parent, {:docker_worker_cleanup, request})

        {:ok,
         %CleanupDockerWorkerResponse{
           result_json: ~s({"removed":1,"errors":[]}),
           version: 1
         }}
      end
    )

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_cleanup_docker_compose_client,
      fn _target, request, _timeout ->
        send(parent, {:docker_compose_cleanup, request})

        {:ok,
         %CleanupDockerComposeResponse{
           result_json: ~s({"removed":["mn-compose-run"],"errors":[]}),
           version: 1
         }}
      end
    )

    on_exit(fn ->
      if previous_target,
        do: System.put_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target),
        else: System.delete_env("MN_NATIVE_SDK_GRPC_TARGET")

      Enum.each(previous_clients, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:mirror_neuron, key),
          else: Application.put_env(:mirror_neuron, key, value)
      end)
    end)
  end

  test "DockerWorker cleanup uses the native SDK for a persisted run" do
    job = %{
      "manifest" => %{
        "metadata" => %{"mn_docker_workers" => %{"submission_id" => "submission-run"}}
      }
    }

    assert RunnerResources.docker_worker?(job)
    assert :ok = RunnerResources.cleanup_docker_worker("run-docker-worker")

    assert_receive {:docker_worker_cleanup, request}
    assert request.job_id == "run-docker-worker"
    assert request.submission_id == ""
  end

  test "Compose cleanup discovers projects from persisted manifest flow nodes" do
    job = %{
      "manifest" => %{
        "flow" => %{
          "nodes" => [
            %{
              "config" => %{
                "runner_module" => "MirrorNeuron.Runner.DockerCompose",
                "mn_docker_compose" => %{
                  "project_name" => "mn-compose-run",
                  "context_path" => "/owned/context",
                  "compose_file" => "/owned/context/docker-compose.yaml"
                }
              }
            }
          ]
        }
      }
    }

    refute RunnerResources.docker_worker?(job)
    assert :ok = RunnerResources.cleanup_prepared_compose_projects(job)

    assert_receive {:docker_compose_cleanup, request}
    assert [project_json] = request.projects_json
    assert Jason.decode!(project_json)["project_name"] == "mn-compose-run"
  end
end
