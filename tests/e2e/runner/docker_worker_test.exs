defmodule MirrorNeuron.Runner.DockerWorkerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.DockerWorker
  alias MirrorNeuron.Sandbox.DockerJobSandbox

  setup do
    previous_docker = System.get_env("MN_DOCKER_BIN")
    previous_skills_root = System.get_env("MN_SKILLS_ROOT")
    previous_workspace_root = System.get_env("MN_WORKSPACE_ROOT")
    previous_buildkit = System.get_env("DOCKER_BUILDKIT")
    previous_worker_buildkit = System.get_env("MN_DOCKER_WORKER_BUILDKIT")
    previous_node_runtime_models = System.get_env("MN_NODE_RUNTIME_MODELS")

    tmp_dir =
      Path.join(System.tmp_dir!(), "mn-docker-worker-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      DockerJobSandbox.cleanup_job_local("job-1")

      if is_nil(previous_docker),
        do: System.delete_env("MN_DOCKER_BIN"),
        else: System.put_env("MN_DOCKER_BIN", previous_docker)

      if is_nil(previous_skills_root),
        do: System.delete_env("MN_SKILLS_ROOT"),
        else: System.put_env("MN_SKILLS_ROOT", previous_skills_root)

      if is_nil(previous_workspace_root),
        do: System.delete_env("MN_WORKSPACE_ROOT"),
        else: System.put_env("MN_WORKSPACE_ROOT", previous_workspace_root)

      if is_nil(previous_buildkit),
        do: System.delete_env("DOCKER_BUILDKIT"),
        else: System.put_env("DOCKER_BUILDKIT", previous_buildkit)

      if is_nil(previous_worker_buildkit),
        do: System.delete_env("MN_DOCKER_WORKER_BUILDKIT"),
        else: System.put_env("MN_DOCKER_WORKER_BUILDKIT", previous_worker_buildkit)

      if is_nil(previous_node_runtime_models),
        do: System.delete_env("MN_NODE_RUNTIME_MODELS"),
        else: System.put_env("MN_NODE_RUNTIME_MODELS", previous_node_runtime_models)

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

  test "uses prepared model endpoint instead of docker model cli", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-model-endpoint")
    args_log = Path.join(tmp_dir, "model-endpoint-args.log")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> #{args_log}
    printf -- '---\\n' >> #{args_log}
    if [ "$1" = "model" ]; then
      exit 9
    fi
    if [ "$1" = "run" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)

    endpoints =
      Jason.encode!(%{
        "nemotron3:latest" => %{
          "model" => "ai/nemotron3:latest",
          "runtime_model" => "ai/nemotron3:latest",
          "api_base" => "http://host.docker.internal:12434/engines/v1"
        }
      })

    assert {:ok, result} =
             DockerWorker.run(
               %{},
               %{
                 "image" => "example/worker:latest",
                 "command" => ["sh", "-lc", "echo worker output"],
                 "docker_bin" => fake_docker,
                 "reuse_shared_container" => false,
                 "environment" => %{
                   "MN_LLM_PROVIDER" => "docker_model_runner",
                   "MN_LLM_RUNTIME_MODEL" => "ai/nemotron3:latest",
                   "MN_MODEL_ENDPOINTS_JSON" => endpoints
                 }
               },
               job_id: "job-model-endpoint",
               agent_id: "worker"
             )

    assert result["stdout"] =~ "worker output"

    calls = docker_calls(args_log)
    assert Enum.any?(calls, &(List.first(&1) == "run"))
    refute Enum.any?(calls, &(List.first(&1) == "model"))
  end

  test "uses advertised node runtime model instead of docker model cli", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-node-runtime-model")
    args_log = Path.join(tmp_dir, "node-runtime-model-args.log")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> #{args_log}
    printf -- '---\\n' >> #{args_log}
    if [ "$1" = "model" ]; then
      exit 9
    fi
    if [ "$1" = "run" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)
    System.put_env("MN_NODE_RUNTIME_MODELS", "gemma4:e2b,nemotron3:latest")

    assert {:ok, result} =
             DockerWorker.run(
               %{},
               %{
                 "image" => "example/worker:latest",
                 "command" => ["sh", "-lc", "echo worker output"],
                 "docker_bin" => fake_docker,
                 "reuse_shared_container" => false,
                 "environment" => %{
                   "MN_LLM_PROVIDER" => "docker_model_runner",
                   "MN_LLM_RUNTIME_MODEL" => "ai/nemotron3:latest"
                 }
               },
               job_id: "job-node-runtime-model",
               agent_id: "worker"
             )

    assert result["stdout"] =~ "worker output"

    calls = docker_calls(args_log)
    assert Enum.any?(calls, &(List.first(&1) == "run"))
    refute Enum.any?(calls, &(List.first(&1) == "model"))
  end

  test "mounts shared storage into shared docker containers", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-shared-storage")
    args_log = Path.join(tmp_dir, "shared-storage-args.log")
    host_shared = Path.join(tmp_dir, "host-shared")
    File.mkdir_p!(host_shared)

    previous_shared_root = System.get_env("MN_SHARED_STORAGE_ROOT")
    previous_host_shared_root = System.get_env("MN_HOST_SHARED_STORAGE_ROOT")
    previous_runtime_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")

    on_exit(fn ->
      DockerJobSandbox.cleanup_job_local("job-shared-storage", %{"docker_bin" => fake_docker})

      if is_nil(previous_shared_root),
        do: System.delete_env("MN_SHARED_STORAGE_ROOT"),
        else: System.put_env("MN_SHARED_STORAGE_ROOT", previous_shared_root)

      if is_nil(previous_host_shared_root),
        do: System.delete_env("MN_HOST_SHARED_STORAGE_ROOT"),
        else: System.put_env("MN_HOST_SHARED_STORAGE_ROOT", previous_host_shared_root)

      if is_nil(previous_runtime_shared_root),
        do: System.delete_env("MN_RUNTIME_SHARED_STORAGE_ROOT"),
        else: System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", previous_runtime_shared_root)
    end)

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
    System.put_env("MN_HOST_SHARED_STORAGE_ROOT", host_shared)
    System.put_env("MN_SHARED_STORAGE_ROOT", "/runtime/shared")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", "/runtime/shared")

    assert {:ok, result} =
             DockerWorker.run(
               %{},
               %{
                 "image" => "example/worker:latest",
                 "command" => ["sh", "-lc", "echo worker output"],
                 "docker_bin" => fake_docker,
                 "environment" => %{
                   "MN_JOB_SHARED_STORAGE_ROOT" => "/runtime/shared/submissions/submission-1"
                 }
               },
               job_id: "job-shared-storage",
               agent_id: "worker"
             )

    assert result["stdout"] =~ "worker output"

    run_call = Enum.find(docker_calls(args_log), &(List.first(&1) == "run"))
    assert "#{host_shared}:/runtime/shared:rw" in run_call
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
      printf 'very long build prelude '
      head -c 5000 /dev/zero | tr '\\0' 'x'
      printf '\\nERROR: No matching distribution found for mirrorneuron-blueprint-support-skill\\n'
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

    assert summary =~ "No matching distribution found for mirrorneuron-blueprint-support-skill"
    refute String.starts_with?(summary, "very long build prelude")
  end

  test "docker worker image builds disable BuildKit by default", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-build-env")
    buildkit_log = Path.join(tmp_dir, "buildkit.log")
    payloads_dir = Path.join(tmp_dir, "payloads")
    docker_worker_dir = Path.join([payloads_dir, "bundle", "docker_worker"])

    File.mkdir_p!(docker_worker_dir)
    File.write!(Path.join(docker_worker_dir, "Dockerfile"), "FROM scratch\n")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    if [ "$1" = "build" ]; then
      printf '%s' "${DOCKER_BUILDKIT:-unset}" > #{buildkit_log}
      echo "build ok"
      exit 0
    fi
    if [ "$1" = "run" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)
    System.put_env("DOCKER_BUILDKIT", "1")
    System.delete_env("MN_DOCKER_WORKER_BUILDKIT")

    assert {:ok, result} =
             DockerWorker.run(
               %{},
               %{
                 "upload_path" => "bundle",
                 "upload_as" => "bundle",
                 "docker_worker_image" => "bundle/docker_worker",
                 "command" => ["sh", "-lc", "echo should run"],
                 "docker_bin" => fake_docker,
                 "reuse_shared_container" => false
               },
               job_id: "job-build-env",
               agent_id: "worker-build",
               payloads_path: payloads_dir
             )

    assert result["stdout"] =~ "worker output"
    assert File.read!(buildkit_log) == "0"
  end

  test "copies skills root build context uploads before building image", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-build-context")
    payloads_dir = Path.join(tmp_dir, "payloads")
    docker_worker_dir = Path.join([payloads_dir, "bundle", "docker_worker"])
    skills_root = Path.join(tmp_dir, "mn-skills")
    support_skill_dir = Path.join(skills_root, "blueprint_support_skill")

    File.mkdir_p!(docker_worker_dir)
    File.mkdir_p!(support_skill_dir)
    File.write!(Path.join(docker_worker_dir, "Dockerfile"), "FROM scratch\n")
    File.write!(Path.join(support_skill_dir, "marker.txt"), "local skill")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    if [ "$1" = "build" ]; then
      context="${@: -1}"
      test -f "$context/build_context/blueprint_support_skill/marker.txt" || exit 7
      echo "build ok"
      exit 0
    fi
    if [ "$1" = "run" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)
    System.delete_env("MN_SKILLS_ROOT")

    assert {:ok, result} =
             DockerWorker.run(
               %{},
               %{
                 "upload_path" => "bundle",
                 "upload_as" => "bundle",
                 "docker_worker_image" => "bundle/docker_worker",
                 "command" => ["sh", "-lc", "echo should run"],
                 "docker_bin" => fake_docker,
                 "reuse_shared_container" => false,
                 "environment" => %{"MN_SKILLS_ROOT" => skills_root},
                 "build_context_upload_paths" => [
                   %{
                     "base" => "skills_root",
                     "source" => "blueprint_support_skill",
                     "target" => "bundle/docker_worker/build_context/blueprint_support_skill"
                   }
                 ]
               },
               job_id: "job-build-context",
               agent_id: "worker-build",
               payloads_path: payloads_dir
             )

    assert result["stdout"] =~ "worker output"
  end

  test "copies workspace root build context uploads before building image", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-workspace-context")
    payloads_dir = Path.join(tmp_dir, "payloads")
    docker_worker_dir = Path.join([payloads_dir, "bundle", "docker_worker"])
    workspace_root = Path.join(tmp_dir, "workspace")
    sdk_dir = Path.join(workspace_root, "mn-python-sdk")

    File.mkdir_p!(docker_worker_dir)
    File.mkdir_p!(sdk_dir)
    File.write!(Path.join(docker_worker_dir, "Dockerfile"), "FROM scratch\n")

    File.write!(
      Path.join(sdk_dir, "pyproject.toml"),
      "[project]\nname='mirrorneuron-python-sdk'\n"
    )

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    if [ "$1" = "build" ]; then
      context="${@: -1}"
      test -f "$context/build_context/mn-python-sdk/pyproject.toml" || exit 7
      echo "build ok"
      exit 0
    fi
    if [ "$1" = "run" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)
    System.delete_env("MN_WORKSPACE_ROOT")

    assert {:ok, result} =
             DockerWorker.run(
               %{},
               %{
                 "upload_path" => "bundle",
                 "upload_as" => "bundle",
                 "docker_worker_image" => "bundle/docker_worker",
                 "command" => ["sh", "-lc", "echo should run"],
                 "docker_bin" => fake_docker,
                 "reuse_shared_container" => false,
                 "environment" => %{"MN_WORKSPACE_ROOT" => workspace_root},
                 "build_context_upload_paths" => [
                   %{
                     "base" => "workspace_root",
                     "source" => "mn-python-sdk",
                     "target" => "bundle/docker_worker/build_context/mn-python-sdk"
                   }
                 ]
               },
               job_id: "job-workspace-context",
               agent_id: "worker-workspace",
               payloads_path: payloads_dir
             )

    assert result["stdout"] =~ "worker output"
  end

  defp docker_calls(path) do
    path
    |> File.read!()
    |> String.split("---\n", trim: true)
    |> Enum.map(fn call -> String.split(call, "\n", trim: true) end)
  end
end
