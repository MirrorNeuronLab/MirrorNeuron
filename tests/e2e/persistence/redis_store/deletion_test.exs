defmodule MirrorNeuron.Persistence.RedisStore.DeletionTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Artifacts.JobStore
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.ServiceRegistry
  alias Mirrorneuron.Cluster.V1.CleanupDockerComposeResponse
  alias Mirrorneuron.Cluster.V1.CleanupDockerWorkerResponse
  alias Mirrorneuron.Cluster.V1.SetResourceResponse

  test "stable job deletion cancels active runs and removes every run and runtime resource" do
    suffix = System.unique_integer([:positive])
    stable_job_id = "stable-delete-#{suffix}"
    run_ids = ["stable-delete-run-a-#{suffix}", "stable-delete-run-b-#{suffix}"]
    old_job_data_root = System.get_env("MN_JOB_DATA_ROOT")
    old_artifact_root = System.get_env("MN_JOB_ARTIFACT_ROOT")
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    old_native_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    old_worker_cleanup =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_cleanup_docker_worker_client)

    old_compose_cleanup =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_cleanup_docker_compose_client)

    old_response_client =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_job_response_client)

    root = Path.join(System.tmp_dir!(), "mn_stable_delete_#{suffix}")
    shared_root = Path.join(root, "shared")
    definition_submission = Path.join([shared_root, "submissions", stable_job_id])
    parent = self()

    System.put_env("MN_JOB_DATA_ROOT", Path.join(root, "job-data"))
    System.put_env("MN_JOB_ARTIFACT_ROOT", Path.join(root, "artifacts"))
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    File.mkdir_p!(definition_submission)

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
           result_json: ~s({"removed":["mn-compose-job"],"errors":[]}),
           version: 1
         }}
      end
    )

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_job_response_client,
      fn _target, request, _timeout ->
        attrs = Jason.decode!(request.resource_json)
        send(parent, {:job_response_stop, attrs})
        {:error, :deadline_exceeded}
      end
    )

    on_exit(fn ->
      Enum.each(run_ids, &RedisStore.delete_job/1)
      RedisStore.delete_job_definition(stable_job_id)
      restore_system_env("MN_JOB_DATA_ROOT", old_job_data_root)
      restore_system_env("MN_JOB_ARTIFACT_ROOT", old_artifact_root)
      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
      restore_system_env("MN_NATIVE_SDK_GRPC_TARGET", old_native_target)
      restore_env(:native_sdk_grpc_cleanup_docker_worker_client, old_worker_cleanup)
      restore_env(:native_sdk_grpc_cleanup_docker_compose_client, old_compose_cleanup)
      restore_env(:native_sdk_grpc_job_response_client, old_response_client)
      File.rm_rf(root)
    end)

    retired_resources = %{
      "mn_storage" => %{
        "submission_id" => "#{stable_job_id}-definition",
        "submission_path" => definition_submission
      },
      "mn_docker_workers" => %{"submission_id" => "#{stable_job_id}-definition"}
    }

    assert {:ok, _path} = MirrorNeuron.JobData.initialize(stable_job_id)

    assert {:ok, _definition} =
             RedisStore.persist_job_definition(stable_job_id, %{
               "job_id" => stable_job_id,
               "status" => "active",
               "run_ids" => run_ids,
               "manifest" => %{
                 "metadata" => retired_resources,
                 "response_service" => %{"enabled" => true}
               }
             })

    runs = [
      {"stable-delete-run-a-#{suffix}", "running",
       %{
         "runner_module" => "MirrorNeuron.Runner.DockerCompose",
         "mn_docker_compose" => %{
           "project_name" => "mn-compose-job",
           "context_path" => "/owned/context",
           "compose_file" => "/owned/context/docker-compose.yaml"
         }
       }},
      {"stable-delete-run-b-#{suffix}", "completed",
       %{
         "runner_module" => "MirrorNeuron.Runner.DockerWorker",
         "docker_worker_container_name" => "mn-worker-job"
       }}
    ]

    for {run_id, status, config} <- runs do
      assert {:ok, _job} =
               RedisStore.persist_job(run_id, %{
                 "job_id" => run_id,
                 "stable_job_id" => stable_job_id,
                 "status" => status,
                 "manifest" => %{"flow" => %{"nodes" => [%{"config" => config}]}}
               })

      assert {:ok, artifact_path} = JobStore.ensure_job_dir(run_id)
      File.write!(Path.join(artifact_path, "result.txt"), "terminal output")

      assert {:ok, _service} =
               ServiceRegistry.register(%{
                 "id" => "service-#{run_id}",
                 "name" => "terminal-service",
                 "job_id" => run_id
               })
    end

    assert {:ok, %{"metadata" => ^retired_resources}} =
             StableJob.delete(stable_job_id, confirmed: true)

    assert_receive {:job_response_stop,
                    %{
                      "operation" => "stop",
                      "job_id" => ^stable_job_id,
                      "force" => true
                    }}

    refute_receive {:docker_worker_cleanup, _request}
    refute_receive {:docker_compose_cleanup, _request}

    assert {:error, _reason} = RedisStore.fetch_job_definition(stable_job_id)
    refute File.exists?(Path.join(MirrorNeuron.JobData.root(), stable_job_id))
    refute File.exists?(definition_submission)

    for run_id <- run_ids do
      assert {:error, _reason} = RedisStore.fetch_job(run_id)
      assert {:ok, artifact_path} = JobStore.job_path(run_id)
      refute File.exists?(artifact_path)
      assert {:ok, []} = ServiceRegistry.list(job_id: run_id)
    end
  end

  test "stable job deletion uses registry ownership without repeating legacy Compose cleanup" do
    suffix = System.unique_integer([:positive])
    stable_job_id = "stable-registry-delete-#{suffix}"
    old_job_data_root = System.get_env("MN_JOB_DATA_ROOT")
    old_native_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    old_native_cleanup =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_native_resource_client)

    old_compose_cleanup =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_cleanup_docker_compose_client)

    root = Path.join(System.tmp_dir!(), "mn_stable_registry_delete_#{suffix}")
    parent = self()

    System.put_env("MN_JOB_DATA_ROOT", Path.join(root, "job-data"))
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_native_resource_client,
      fn _target, request, _timeout ->
        send(parent, {:native_resource_cleanup, Jason.decode!(request.resource_json)})

        {:ok,
         %SetResourceResponse{
           resource_json: ~s({"removed_count":1,"errors":[]}),
           version: 1
         }}
      end
    )

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_cleanup_docker_compose_client,
      fn _target, request, _timeout ->
        send(parent, {:unexpected_legacy_compose_cleanup, request})

        {:ok,
         %CleanupDockerComposeResponse{
           result_json: ~s({"removed":[],"errors":["owned source is gone"]}),
           version: 1
         }}
      end
    )

    on_exit(fn ->
      RedisStore.delete_job_definition(stable_job_id)
      restore_system_env("MN_JOB_DATA_ROOT", old_job_data_root)
      restore_system_env("MN_NATIVE_SDK_GRPC_TARGET", old_native_target)
      restore_env(:native_sdk_grpc_native_resource_client, old_native_cleanup)
      restore_env(:native_sdk_grpc_cleanup_docker_compose_client, old_compose_cleanup)
      File.rm_rf(root)
    end)

    native_resources = %{
      "version" => 1,
      "resources" => [
        %{
          "kind" => "docker_compose",
          "scope" => "definition",
          "external_id" => "mn-compose-registry-definition"
        }
      ]
    }

    assert {:ok, _path} = MirrorNeuron.JobData.initialize(stable_job_id)

    assert {:ok, _definition} =
             RedisStore.persist_job_definition(stable_job_id, %{
               "job_id" => stable_job_id,
               "status" => "active",
               "run_ids" => [],
               "manifest" => %{
                 "metadata" => %{"mn_native_resources" => native_resources},
                 "flow" => %{
                   "nodes" => [
                     %{
                       "config" => %{
                         "runner_module" => "MirrorNeuron.Runner.DockerCompose",
                         "mn_docker_compose" => %{
                           "project_name" => "mn-compose-registry-definition",
                           "context_path" => "/retired/context",
                           "compose_file" => "/retired/context/docker-compose.yaml",
                           "generated_env_file" => "/retired/context/project.env",
                           "services" => ["app"]
                         }
                       }
                     }
                   ]
                 }
               }
             })

    assert {:ok, %{"metadata" => %{"mn_native_resources" => ^native_resources}}} =
             StableJob.delete(stable_job_id, confirmed: true)

    assert_receive {:native_resource_cleanup,
                    %{
                      "kind" => "native_resource",
                      "operation" => "cleanup",
                      "job_id" => ^stable_job_id,
                      "run_id" => ^stable_job_id
                    }}

    refute_receive {:unexpected_legacy_compose_cleanup, _request}
    assert {:error, _reason} = RedisStore.fetch_job_definition(stable_job_id)
  end

  test "run deletion cancels active DockerWorker and DockerCompose runs and detaches them" do
    suffix = System.unique_integer([:positive])
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    previous_worker_cleanup =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_cleanup_docker_worker_client)

    previous_compose_cleanup =
      Application.get_env(:mirror_neuron, :native_sdk_grpc_cleanup_docker_compose_client)

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

    runs = [
      {"run-delete-worker-#{suffix}",
       %{
         "runner_module" => "MirrorNeuron.Runner.DockerWorker",
         "docker_worker_container_name" => "mn-worker-run"
       }},
      {"run-delete-compose-#{suffix}",
       %{
         "runner_module" => "MirrorNeuron.Runner.DockerCompose",
         "mn_docker_compose" => %{
           "project_name" => "mn-compose-run",
           "context_path" => "/owned/context",
           "compose_file" => "/owned/context/docker-compose.yaml"
         }
       }}
    ]

    on_exit(fn ->
      Enum.each(runs, fn {run_id, _config} ->
        _ = RedisStore.delete_job(run_id)
        _ = RedisStore.delete_job_definition("job-#{run_id}")
      end)

      restore_system_env("MN_NATIVE_SDK_GRPC_TARGET", previous_target)
      restore_env(:native_sdk_grpc_cleanup_docker_worker_client, previous_worker_cleanup)
      restore_env(:native_sdk_grpc_cleanup_docker_compose_client, previous_compose_cleanup)
    end)

    for {run_id, config} <- runs do
      stable_job_id = "job-#{run_id}"

      assert {:ok, _definition} =
               RedisStore.persist_job_definition(stable_job_id, %{
                 "job_id" => stable_job_id,
                 "status" => "active",
                 "run_ids" => [run_id]
               })

      assert {:ok, _run} =
               RedisStore.persist_job(run_id, %{
                 "job_id" => run_id,
                 "stable_job_id" => stable_job_id,
                 "status" => "running",
                 "manifest" => %{"flow" => %{"nodes" => [%{"config" => config}]}}
               })

      assert :ok = StableJob.delete_run(run_id, confirmed: true)
      assert {:error, _reason} = RedisStore.fetch_job(run_id)
      assert {:ok, definition} = RedisStore.fetch_job_definition(stable_job_id)
      assert definition["run_ids"] == []
    end

    refute_receive {:docker_worker_cleanup, _request}
    refute_receive {:docker_compose_cleanup, _request}
  end
end
