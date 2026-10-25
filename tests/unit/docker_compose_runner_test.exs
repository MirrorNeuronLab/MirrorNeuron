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
    parent = self()

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
               event_callback: fn type, payload ->
                 send(parent, {:health_event, type, payload})
               end
             )

    assert_receive {:health_event, "service_lifecycle", %{"details" => %{"state" => "starting"}}}
    assert_receive {:health_event, "service_lifecycle", %{"details" => %{"state" => "failed"}}}
    refute_received {:health_event, "service_lifecycle", %{"details" => %{"state" => "serving"}}}

    assert_receive {:prepare, prepare}

    manifest = Jason.decode!(prepare.manifest_json)
    assert manifest["agents"]["nodes"] |> hd() |> Map.fetch!("node_id") == "warehouse"
    refute Map.has_key?(manifest, "nodes")

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

  test "native lifecycle becomes serving only after health and retains attempt identity" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Application.put_env(:mirror_neuron, :native_sdk_grpc_docker_compose_status_client, fn _,
                                                                                          _,
                                                                                          _ ->
      count = Agent.get_and_update(counter, fn value -> {value, value + 1} end)

      {:ok,
       %DockerComposeStatusResponse{
         result_json: Jason.encode!(%{"ready" => count == 0}),
         version: 1
       }}
    end)

    config = %{
      "mn_docker_compose" => %{"project_name" => "mn-compose-runner"},
      "environment" => %{
        "MN_JOB_ID" => "stable-job",
        "MN_RUN_ID" => "execution",
        "MN_WORKFLOW_RUN_ID" => "stale",
        "MN_WORKFLOW_STEP_ID" => "stale",
        "MN_WORKFLOW_ATTEMPT_ID" => "stale"
      }
    }

    message =
      MirrorNeuron.Message.new("physical", "source", "listener", "input", %{},
        headers: %{
          "mn.workflow.run_id" => "physical",
          "mn.workflow.step_id" => "serve",
          "mn.workflow.attempt_id" => "attempt-2"
        }
      )

    assert {:error, "DockerCompose project is not healthy"} =
             DockerCompose.run(%{}, config,
               job_id: "physical",
               agent_id: "listener",
               message: message,
               sleep: fn _ -> :ok end,
               event_callback: fn type, payload ->
                 send(parent, {:native_event, type, payload})
               end
             )

    observations =
      for _ <- 1..3 do
        assert_receive {:native_event, "service_lifecycle", %{"details" => receipt}}
        receipt
      end

    assert Enum.map(observations, & &1["state"]) == ["starting", "serving", "failed"]
    assert Enum.map(observations, & &1["sequence"]) == [1, 2, 3]
    assert observations |> Enum.map(& &1["generation"]) |> Enum.uniq() |> length() == 1

    for receipt <- observations do
      assert Map.take(receipt, [
               "job_id",
               "execution_id",
               "run_id",
               "step_id",
               "service_id",
               "attempt_id"
             ]) ==
               %{
                 "job_id" => "stable-job",
                 "execution_id" => "execution",
                 "run_id" => "physical",
                 "step_id" => "serve",
                 "service_id" => "listener",
                 "attempt_id" => "attempt-2"
               }

      assert {:ok, _, _} = DateTime.from_iso8601(receipt["timestamp"])
    end

    assert_receive {:cleanup, _}
    Agent.stop(counter)
  end

  test "failed preparation publishes only a bounded failure reason" do
    parent = self()

    Application.put_env(:mirror_neuron, :native_sdk_grpc_prepare_docker_compose_client, fn _,
                                                                                           _,
                                                                                           _ ->
      {:error, "private-native-diagnostic"}
    end)

    config = %{"mn_docker_compose" => %{"project_name" => "mn-compose-runner"}}

    assert {:error, _} =
             DockerCompose.run(%{}, config,
               agent_id: "listener",
               event_callback: fn type, payload ->
                 send(parent, {:failed_prepare_event, type, payload})
               end
             )

    assert_receive {:failed_prepare_event, "service_lifecycle",
                    %{"details" => %{"state" => "starting"}}}

    assert_receive {:failed_prepare_event, "service_lifecycle", %{"details" => receipt}}
    assert receipt["state"] == "failed"
    assert receipt["reason"] == "native_compose_prepare_failed"
    refute Jason.encode!(receipt) =~ "private-native-diagnostic"
    refute_received {:cleanup, _}
  end
end
