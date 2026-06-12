defmodule MirrorNeuron.Runner.DockerWorkerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.DockerWorker
  alias MirrorNeuron.Sandbox.DockerJobSandbox

  setup do
    previous = System.get_env("MN_DOCKER_BIN")
    tmp_dir = Path.join(System.tmp_dir!(), "mn-docker-worker-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      DockerJobSandbox.cleanup_job_local("job-1")
      if is_nil(previous), do: System.delete_env("MN_DOCKER_BIN"), else: System.put_env("MN_DOCKER_BIN", previous)
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "runs docker worker without publishing host ports", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker")
    args_log = Path.join(tmp_dir, "args.log")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> #{args_log}
    printf -- '---\\n' >> #{args_log}
    if [ "$1" = "run" ]; then
      echo "container-id"
      exit 0
    fi
    if [ "$1" = "exec" ] && [ "$2" = "-w" ]; then
      echo '__MN_EVENT__{"type":"tool_call_completed","payload":{"category":"tool","message":"Browsed example.com","tool_name":"w3m","target":"https://example.com","status":"completed"}}'
      echo "worker output"
      exit 0
    fi
    if [ "$1" = "rm" ] && [ "$2" = "-f" ]; then
      exit 0
    fi
    if [ "$1" = "inspect" ]; then
      echo "No such container" >&2
      exit 1
    fi
    if [ "$1" = "cp" ]; then
      exit 0
    fi
    if [ "$1" = "exec" ]; then
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)
    parent = self()

    assert {:ok, result} =
             DockerWorker.run(
               %{"hello" => "world"},
               %{
                 "image" => "example/worker:latest",
                 "command" => ["sh", "-lc", "echo worker output"],
                 "environment" => %{"EXAMPLE" => "1"},
                 "docker_bin" => fake_docker
               },
               job_id: "job-1",
               agent_id: "worker",
               event_callback: fn event_type, payload ->
                 send(parent, {:docker_event, event_type, payload})
               end
             )

    assert result["runner"] == "docker_worker"
    assert result["stdout"] =~ "worker output"
    refute result["stdout"] =~ "__MN_EVENT__"

    assert_receive {:docker_event, "docker_worker_command_started", %{"category" => "system"}}
    assert_receive {:docker_event, "tool_call_completed",
                    %{
                      "category" => "tool",
                      "tool_name" => "w3m",
                      "target" => "https://example.com",
                      "agent_id" => "worker"
                    }}
    assert_receive {:docker_event, "docker_worker_command_completed", %{"category" => "system"}}

    args = File.read!(args_log)
    calls = docker_calls(args_log)
    run_call = Enum.find(calls, &(List.first(&1) == "run"))

    assert args =~ "run\n"
    assert args =~ "-d\n"
    assert args =~ "exec\n"
    assert args =~ "cp\n"
    assert args =~ "--name\n"
    refute args =~ "--rm\n"
    refute "-p" in run_call
    refute "--publish" in run_call
  end

  test "reuses one shared Docker container for multiple agents in a job", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-reuse")
    args_log = Path.join(tmp_dir, "reuse-args.log")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> #{args_log}
    printf -- '---\\n' >> #{args_log}
    if [ "$1" = "run" ]; then
      echo "container-id"
      exit 0
    fi
    if [ "$1" = "exec" ] && [ "$2" = "-w" ]; then
      echo "worker output"
      exit 0
    fi
    if [ "$1" = "rm" ] && [ "$2" = "-f" ]; then
      exit 0
    fi
    if [ "$1" = "inspect" ]; then
      echo "No such container" >&2
      exit 1
    fi
    if [ "$1" = "cp" ]; then
      exit 0
    fi
    if [ "$1" = "exec" ]; then
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)

    config = %{
      "image" => "example/worker:latest",
      "command" => ["sh", "-lc", "echo worker output"],
      "docker_bin" => fake_docker
    }

    assert {:ok, _first} =
             DockerWorker.run(%{"step" => 1}, config, job_id: "job-1", agent_id: "agent-a")

    assert {:ok, _second} =
             DockerWorker.run(%{"step" => 2}, config, job_id: "job-1", agent_id: "agent-b")

    assert :ok = DockerJobSandbox.cleanup_job_local("job-1", config)

    calls = docker_calls(args_log)
    assert Enum.count(calls, &(List.first(&1) == "run")) == 1
    assert Enum.count(calls, &(List.first(&1) == "cp")) == 2
    assert Enum.count(calls, &(Enum.take(&1, 2) == ["exec", "-w"])) == 2
    assert Enum.any?(calls, &(Enum.take(&1, 2) == ["rm", "-f"]))
  end

  test "emits compact lifecycle events when docker worker image build fails", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-build-fails")
    payloads_dir = Path.join(tmp_dir, "payloads")
    docker_worker_dir = Path.join([payloads_dir, "bundle", "docker_worker"])

    File.mkdir_p!(docker_worker_dir)
    File.write!(Path.join(docker_worker_dir, "Dockerfile"), "FROM scratch\n")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    if [ "$1" = "build" ]; then
      echo "build failed because apt package was unavailable"
      exit 9
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)
    parent = self()

    assert {:error, reason} =
             DockerWorker.run(
               %{},
               %{
                 "upload_path" => "bundle",
                 "upload_as" => "bundle",
                 "docker_worker_image" => "bundle/docker_worker",
                 "command" => ["sh", "-lc", "echo should not run"],
                 "docker_bin" => fake_docker
               },
               job_id: "job-build-fail",
               agent_id: "worker-build",
               payloads_path: payloads_dir,
               event_callback: fn event_type, payload ->
                 send(parent, {:docker_event, event_type, payload})
               end
             )

    assert reason =~ "failed to build docker_worker image"
    assert_receive {:docker_event, "docker_worker_build_started", %{"category" => "system"}}
    assert_receive {:docker_event, "docker_worker_build_failed",
                    %{
                      "category" => "error",
                      "message" => "DockerWorker image build failed",
                      "result_summary" => summary
                    }}
    assert summary =~ "apt package was unavailable"
  end

  defp docker_calls(path) do
    path
    |> File.read!()
    |> String.split("---\n", trim: true)
    |> Enum.map(fn call -> String.split(call, "\n", trim: true) end)
  end
end
