defmodule MirrorNeuron.Runner.DockerComposeTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.DockerCompose

  alias Mirrorneuron.Cluster.V1.{
    CleanupDockerComposeResponse,
    DockerComposeStatusResponse,
    PrepareDockerComposeResponse
  }

  @client_keys [
    :native_sdk_grpc_prepare_docker_compose_client,
    :native_sdk_grpc_docker_compose_status_client,
    :native_sdk_grpc_cleanup_docker_compose_client
  ]

  setup do
    previous_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    previous_clients = Map.new(@client_keys, &{&1, Application.get_env(:mirror_neuron, &1)})
    parent = self()
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_prepare_docker_compose_client,
      fn _target, request, _timeout ->
        send(parent, {:prepare, request})

        {:ok,
         %PrepareDockerComposeResponse{
           result_json:
             Jason.encode!(%{
               "projects" => [
                 %{
                   "project_name" => "mn-compose-runner",
                   "context_path" => "/owned/context",
                   "compose_file" => "/owned/context/docker-compose.yaml",
                   "generated_env_file" => "/owned/project.env",
                   "services" => ["warehouse"],
                   "health" => []
                 }
               ]
             }),
           version: 1
         }}
      end
    )

    Application.put_env(:mirror_neuron, :native_sdk_grpc_docker_compose_status_client, fn _target,
                                                                                          request,
                                                                                          _timeout ->
      send(parent, {:status, request})
      {:ok, %DockerComposeStatusResponse{result_json: ~s({"ready":false}), version: 1}}
    end)

    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_cleanup_docker_compose_client,
      fn _target, request, _timeout ->
        send(parent, {:cleanup, request})

        {:ok,
         %CleanupDockerComposeResponse{
           result_json: ~s({"removed":["mn-compose-runner"]}),
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

    :ok
  end

  test "health failure tears down the exact prepared Compose project" do
    config = %{
      "mn_docker_compose" => %{"project_name" => "mn-compose-runner"},
      "compose" => %{
        "context" => "docker_compose/turtlebot-maze",
        "file" => "docker-compose.yaml",
        "env_file" => "mirrorneuron/warehouse.env",
        "services" => ["warehouse"]
      }
    }

    assert {:error, "DockerCompose project is not healthy"} =
             DockerCompose.run(%{}, config, agent_id: "warehouse")

    assert_receive {:prepare, prepare}

    assert Jason.decode!(prepare.manifest_json)["nodes"] |> hd() |> Map.fetch!("node_id") ==
             "warehouse"

    assert_receive {:status, _status}
    assert_receive {:cleanup, cleanup}
    assert [project_json] = cleanup.projects_json
    assert Jason.decode!(project_json)["project_name"] == "mn-compose-runner"
  end

  test "event callback return values do not terminate the Compose runner" do
    config = %{
      "mn_docker_compose" => %{"project_name" => "mn-compose-runner"},
      "compose" => %{
        "context" => "docker_compose/turtlebot-maze",
        "file" => "docker-compose.yaml",
        "env_file" => "mirrorneuron/warehouse.env",
        "services" => ["warehouse"]
      }
    }

    assert {:error, "DockerCompose project is not healthy"} =
             DockerCompose.run(%{}, config,
               agent_id: "warehouse",
               event_callback: fn _event_type, _payload ->
                 {:agent_event, "warehouse", "docker_compose_ready", %{}}
               end
             )

    assert_receive {:prepare, _prepare}
    assert_receive {:status, _status}
    assert_receive {:cleanup, _cleanup}
  end

  test "cleanup can retire an already-prepared project during a service pause" do
    config = %{
      "mn_docker_compose" => %{
        "project_name" => "mn-compose-runner",
        "context_path" => "/owned/context",
        "compose_file" => "/owned/context/docker-compose.yaml",
        "generated_env_file" => "/owned/project.env",
        "services" => ["warehouse"]
      }
    }

    assert :ok = DockerCompose.cleanup_prepared_project(config)
    assert_receive {:cleanup, cleanup}
    assert [project_json] = cleanup.projects_json
    assert Jason.decode!(project_json)["project_name"] == "mn-compose-runner"
  end

  test "cleanup reports native project errors instead of acknowledging a stale project" do
    Application.put_env(
      :mirror_neuron,
      :native_sdk_grpc_cleanup_docker_compose_client,
      fn _target, _request, _timeout ->
        {:ok,
         %CleanupDockerComposeResponse{
           result_json: ~s({"removed":[],"errors":["owned source is missing"]}),
           version: 1
         }}
      end
    )

    config = %{
      "mn_docker_compose" => %{
        "project_name" => "mn-compose-runner",
        "context_path" => "/owned/context",
        "compose_file" => "/owned/context/docker-compose.yaml",
        "generated_env_file" => "/owned/project.env",
        "services" => ["warehouse"]
      }
    }

    assert {:error, reason} = DockerCompose.cleanup_prepared_project(config)
    assert reason =~ "owned source is missing"
  end
end
