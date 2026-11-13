defmodule MirrorNeuron.Runner.DockerWorkerTest.PreparationTest do
  use MirrorNeuron.DockerWorkerCase, async: false

  alias MirrorNeuron.Runner.DockerWorker

  test "rejects unprepared DockerWorker image builds", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-build-fails")
    payloads_dir = Path.join(tmp_dir, "payloads")
    docker_worker_dir = Path.join([payloads_dir, "bundle", "docker_worker"])

    File.mkdir_p!(docker_worker_dir)
    File.write!(Path.join(docker_worker_dir, "Dockerfile"), "FROM scratch\n")

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
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

  # These fixtures represent already-running SDK-prepared containers. Tests for
  # stopped and missing containers live at the sandbox lifecycle boundary.
end
