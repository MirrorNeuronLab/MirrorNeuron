defmodule MirrorNeuron.Runtime.RunnerResourcesTest do
  use ExUnit.Case, async: false

  defmodule LocalNodeAdapter do
    def self, do: :local@node
    def list, do: []

    def rpc_call(_node, module, function, args, _timeout),
      do: apply(module, function, args)
  end

  alias MirrorNeuron.Runtime.RunnerResources

  alias Mirrorneuron.Cluster.V1.{
    CleanupDockerComposeResponse,
    CleanupDockerWorkerResponse,
    SetResourceResponse
  }

  @client_keys [
    :native_sdk_grpc_cleanup_docker_compose_client,
    :native_sdk_grpc_cleanup_docker_worker_client,
    :native_sdk_grpc_native_resource_client
  ]

  setup do
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_clients = Map.new(@client_keys, &{&1, Application.get_env(:mirror_neuron, &1)})
    previous_node_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)
    parent = self()

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    Application.put_env(:mirror_neuron, :cluster_node_adapter, LocalNodeAdapter)

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
      :native_sdk_grpc_native_resource_client,
      fn _target, request, _timeout ->
        send(parent, {:native_resource_cleanup, Jason.decode!(request.resource_json)})

        {:ok,
         %SetResourceResponse{
           resource_json: ~s({"removed_count":0,"errors":[]}),
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

      if is_nil(previous_node_adapter),
        do: Application.delete_env(:mirror_neuron, :cluster_node_adapter),
        else:
          Application.put_env(
            :mirror_neuron,
            :cluster_node_adapter,
            previous_node_adapter
          )
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

  test "unified cleanup uses the native resource registry boundary" do
    assert :ok = RunnerResources.cleanup_native_resources("run-native")

    assert_receive {:native_resource_cleanup,
                    %{
                      "kind" => "native_resource",
                      "operation" => "cleanup",
                      "job_id" => "run-native"
                    }}
  end

  test "exact external-id cleanup uses kind-scoped native resource selectors" do
    assert :ok =
             RunnerResources.cleanup_native_resource_external_ids(
               "openshell",
               ["mirror-neuron-job-retired"]
             )

    assert_receive {:native_resource_cleanup,
                    %{
                      "kind" => "native_resource",
                      "operation" => "cleanup",
                      "resource_kinds" => ["openshell"],
                      "external_ids" => ["mirror-neuron-job-retired"]
                    }}
  end

  test "retired cleanup preserves exact resources reused by the current revision" do
    retired = %{
      "metadata" => %{
        "mn_native_resources" => %{
          "resources" => [
            %{
              "kind" => "openshell",
              "external_id" => "mirror-neuron-job-reused"
            },
            %{
              "kind" => "openshell",
              "external_id" => "mirror-neuron-job-retired"
            }
          ]
        }
      }
    }

    current = %{
      "manifest" => %{
        "metadata" => %{
          "mn_native_resources" => %{
            "resources" => [
              %{
                "kind" => "openshell",
                "external_id" => "mirror-neuron-job-reused"
              }
            ]
          }
        }
      }
    }

    assert :ok = RunnerResources.cleanup_retired_native_resources(retired, current)

    assert_receive {:native_resource_cleanup,
                    %{
                      "resource_kinds" => ["openshell"],
                      "external_ids" => ["mirror-neuron-job-retired"]
                    }}
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
