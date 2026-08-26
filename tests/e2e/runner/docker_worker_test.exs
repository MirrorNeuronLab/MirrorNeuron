defmodule MirrorNeuron.Runner.DockerWorkerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.DockerWorker
  alias MirrorNeuron.Sandbox.DockerJobSandbox

  setup do
    previous_skills_root = System.get_env("MN_SKILLS_ROOT")
    previous_workspace_root = System.get_env("MN_WORKSPACE_ROOT")
    previous_buildkit = System.get_env("DOCKER_BUILDKIT")
    previous_worker_buildkit = System.get_env("MN_DOCKER_WORKER_BUILDKIT")
    previous_node_runtime_models = System.get_env("MN_NODE_RUNTIME_MODELS")
    previous_prepared_container = System.get_env("MN_DOCKER_WORKER_CONTAINER_NAME")
    prepared_container = "mn-test-prepared-#{System.unique_integer([:positive])}"

    System.put_env("MN_DOCKER_WORKER_CONTAINER_NAME", prepared_container)

    tmp_dir =
      Path.join(System.tmp_dir!(), "mn-docker-worker-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
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

      if is_nil(previous_prepared_container),
        do: System.delete_env("MN_DOCKER_WORKER_CONTAINER_NAME"),
        else: System.put_env("MN_DOCKER_WORKER_CONTAINER_NAME", previous_prepared_container)

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, prepared_container: prepared_container}
  end

  test "runs in an SDK-prepared worker without publishing host ports", %{
    tmp_dir: tmp_dir,
    prepared_container: prepared_container
  } do
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
    cleanup_docker_job_on_exit("job-1", fake_docker)
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

    assert args =~ "exec\n"
    assert args =~ "cp\n"
    assert result["container_name"] == prepared_container
    assert Enum.any?(calls, &("MN_EXECUTION_NODE=#{Node.self()}" in &1))

    refute Enum.any?(calls, &(List.first(&1) == "run"))
    refute args =~ "--rm\n"
    refute args =~ "--publish\n"
  end

  test "executes in the Compose-prepared worker instead of creating a second container", %{
    tmp_dir: tmp_dir
  } do
    fake_docker = Path.join(tmp_dir, "fake-docker-prepared")
    args_log = Path.join(tmp_dir, "prepared-args.log")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> #{args_log}
    printf -- '---\\n' >> #{args_log}
    if [ "$1" = "exec" ] && [ "$2" = "-w" ]; then
      echo "prepared worker output"
      exit 0
    fi
    if [ "$1" = "cp" ] || [ "$1" = "exec" ]; then
      exit 0
    fi
    exit 9
    """)

    File.chmod!(fake_docker, 0o755)

    assert {:ok, result} =
             DockerWorker.run(
               %{"hello" => "compose"},
               %{
                 "image" => "example/worker:latest",
                 "command" => ["sh", "-lc", "echo worker output"],
                 "docker_bin" => fake_docker,
                 "docker_worker_container_name" => "mn-compose-worker",
                 "reuse_shared_container" => false
               },
               job_id: "prepared-job",
               agent_id: "worker"
             )

    assert result["container_name"] == "mn-compose-worker"
    assert result["stdout"] =~ "prepared worker output"

    calls = docker_calls(args_log)
    refute Enum.any?(calls, &(List.first(&1) == "run"))
    assert Enum.any?(calls, &(Enum.take(&1, 2) == ["exec", "-w"]))
    assert Enum.any?(calls, &(List.first(&1) == "cp"))
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
    if [ "$1" = "exec" ] && [ "$2" = "-w" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)

    endpoints =
      Jason.encode!(%{
        "nemotron3" => %{
          "model" => "nemotron3",
          "runtime_model" => "nemotron3",
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
    refute Enum.any?(calls, &(List.first(&1) == "run"))
    refute Enum.any?(calls, &(List.first(&1) == "model"))
  end

  test "lets the managed SDK prepare a model lazily and forwards model-node events", %{
    tmp_dir: tmp_dir
  } do
    fake_docker = Path.join(tmp_dir, "fake-docker-managed-model")
    args_log = Path.join(tmp_dir, "managed-model-args.log")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> #{args_log}
    printf -- '---\\n' >> #{args_log}
    if [ "$1" = "model" ]; then
      exit 9
    fi
    if [ "$1" = "exec" ] && [ "$2" = "-w" ]; then
      echo '__MN_EVENT__{"type":"runtime_model_install_started","payload":{"category":"system","message":"Installing gemma4:e2b on mirror_neuron@10.0.4.27.","model":"gemma4:e2b","node":"mirror_neuron@10.0.4.27","status":"started"}}'
      echo '__MN_EVENT__{"type":"runtime_model_ready","payload":{"category":"system","message":"Runtime model gemma4:e2b is ready on mirror_neuron@10.0.4.27.","model":"gemma4:e2b","node":"mirror_neuron@10.0.4.27","status":"installed"}}'
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    parent = self()
    execution_node = to_string(Node.self())

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
                   "MN_LLM_MODEL" => "default",
                   "MN_RUNTIME_MODEL_MANAGED" => "1"
                 }
               },
               job_id: "job-managed-model",
               agent_id: "worker",
               event_callback: fn event_type, payload ->
                 send(parent, {:docker_event, event_type, payload})
               end
             )

    assert result["stdout"] =~ "worker output"

    assert_receive {:docker_event, "docker_worker_model_prepare_deferred",
                    %{
                      "model" => "default",
                      "execution_node" => ^execution_node,
                      "preparation" => "lazy_first_use"
                    }}

    assert_receive {:docker_event, "runtime_model_install_started",
                    %{
                      "model" => "gemma4:e2b",
                      "node" => "mirror_neuron@10.0.4.27",
                      "message" => "Installing gemma4:e2b on mirror_neuron@10.0.4.27."
                    }}

    assert_receive {:docker_event, "runtime_model_ready",
                    %{
                      "model" => "gemma4:e2b",
                      "node" => "mirror_neuron@10.0.4.27"
                    }}

    refute_received {:docker_event, "docker_worker_model_not_prepared", _payload}

    calls = docker_calls(args_log)
    refute Enum.any?(calls, &(List.first(&1) == "run"))
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
    if [ "$1" = "exec" ] && [ "$2" = "-w" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_NODE_RUNTIME_MODELS", "gemma4:e2b,nemotron3")

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
    refute Enum.any?(calls, &(List.first(&1) == "run"))
    refute Enum.any?(calls, &(List.first(&1) == "model"))
  end

  test "passes shared storage paths to an SDK-prepared docker container", %{tmp_dir: tmp_dir} do
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

    calls = docker_calls(args_log)
    refute Enum.any?(calls, &(List.first(&1) == "run"))

    assert Enum.any?(
             calls,
             &("MN_JOB_SHARED_STORAGE_ROOT=/runtime/shared/submissions/submission-1" in &1)
           )
  end

  test "uses one SDK-prepared Docker container for multiple agents in a job", %{
    tmp_dir: tmp_dir,
    prepared_container: prepared_container
  } do
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
    cleanup_docker_job_on_exit("job-1", fake_docker)

    config = %{
      "image" => "example/worker:latest",
      "command" => ["sh", "-lc", "echo worker output"],
      "docker_bin" => fake_docker,
      "docker_worker_container_name" => prepared_container
    }

    assert {:ok, _first} =
             DockerWorker.run(%{"step" => 1}, config, job_id: "job-1", agent_id: "agent-a")

    assert {:ok, _second} =
             DockerWorker.run(%{"step" => 2}, config, job_id: "job-1", agent_id: "agent-b")

    assert :ok = DockerJobSandbox.cleanup_job_local("job-1", config)

    calls = docker_calls(args_log)
    refute Enum.any?(calls, &(List.first(&1) == "run"))
    assert Enum.count(calls, &(List.first(&1) == "cp")) == 2
    assert Enum.count(calls, &(Enum.take(&1, 2) == ["exec", "-w"])) == 2
    refute Enum.any?(calls, &(Enum.take(&1, 2) == ["rm", "-f"]))
  end

  test "does not clean SDK-owned prepared containers", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-orphan-cleanup")
    args_log = Path.join(tmp_dir, "orphan-cleanup-args.log")

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\n' "$@" >> #{args_log}
    printf -- '---\n' >> #{args_log}
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)

    assert :ok =
             DockerJobSandbox.cleanup_job_local(
               "job-orphan-cleanup",
               %{
                 "docker_bin" => fake_docker,
                 "docker_shared_container_prefix" => "new-prefix"
               }
             )

    refute File.exists?(args_log)
  end

  test "does not retain local ownership of SDK-prepared containers", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-cleanup-retry")
    job_id = "job-cleanup-retry"

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    config = %{"docker_bin" => fake_docker, "docker_worker_container_name" => "prepared"}

    assert {:ok, %{"container_name" => "prepared"}} =
             DockerJobSandbox.ensure(job_id, "example/worker:latest", config)

    assert :ok = DockerJobSandbox.cleanup_job_local(job_id, config)
    assert Registry.lookup(MirrorNeuron.Sandbox.Registry, {:docker_worker, job_id}) == []
  end

  test "rejects unprepared DockerWorker image builds", %{tmp_dir: tmp_dir} do
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
               payloads_path: payloads_dir
             )

    assert reason =~ "docker_worker image build is owned by mn-python-sdk/API/CLI"
  end

  test "rejects DockerWorker image builds before invoking Docker", %{tmp_dir: tmp_dir} do
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
    System.put_env("DOCKER_BUILDKIT", "1")
    System.delete_env("MN_DOCKER_WORKER_BUILDKIT")

    assert {:error, reason} =
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

    assert reason =~ "docker_worker image build is owned by mn-python-sdk/API/CLI"
    refute File.exists?(buildkit_log)
  end

  test "rejects skills build-context uploads until the SDK prepares the image", %{
    tmp_dir: tmp_dir
  } do
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
    System.delete_env("MN_SKILLS_ROOT")

    assert {:error, reason} =
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

    assert reason =~ "docker_worker image build is owned by mn-python-sdk/API/CLI"
  end

  test "rejects workspace build-context uploads until the SDK prepares the image", %{
    tmp_dir: tmp_dir
  } do
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
    System.delete_env("MN_WORKSPACE_ROOT")

    assert {:error, reason} =
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

    assert reason =~ "docker_worker image build is owned by mn-python-sdk/API/CLI"
  end

  defp cleanup_docker_job_on_exit(job_id, fake_docker) do
    on_exit(fn ->
      DockerJobSandbox.cleanup_job_local(job_id, %{"docker_bin" => fake_docker})
    end)
  end

  defp docker_calls(path) do
    path
    |> File.read!()
    |> String.split("---\n", trim: true)
    |> Enum.map(fn call -> String.split(call, "\n", trim: true) end)
  end
end
