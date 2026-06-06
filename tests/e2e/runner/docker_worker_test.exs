defmodule MirrorNeuron.Runner.DockerWorkerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.DockerWorker

  setup do
    previous = System.get_env("MN_DOCKER_BIN")
    tmp_dir = Path.join(System.tmp_dir!(), "mn-docker-worker-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
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
    printf '%s\\n' "$@" > #{args_log}
    if [ "$1" = "run" ]; then
      echo "worker output"
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)

    assert {:ok, result} =
             DockerWorker.run(
               %{"hello" => "world"},
               %{
                 "image" => "example/worker:latest",
                 "command" => ["sh", "-lc", "echo worker output"],
                 "environment" => %{"EXAMPLE" => "1"}
               },
               job_id: "job-1",
               agent_id: "worker"
             )

    assert result["runner"] == "docker_worker"
    assert result["stdout"] =~ "worker output"

    args = File.read!(args_log)
    assert args =~ "run\n"
    assert args =~ "--rm\n"
    assert args =~ "--name\n"
    refute args =~ "-p\n"
    refute args =~ "--publish\n"
  end
end
