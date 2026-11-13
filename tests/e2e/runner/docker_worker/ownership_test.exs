defmodule MirrorNeuron.Runner.DockerWorkerTest.OwnershipTest do
  use MirrorNeuron.DockerWorkerCase, async: false

  alias MirrorNeuron.Runner.DockerWorker
  alias MirrorNeuron.Sandbox.DockerJobSandbox

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

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
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
end
