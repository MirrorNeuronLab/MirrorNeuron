defmodule MirrorNeuron.Sandbox.DockerJobSandboxTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Sandbox.DockerJobSandbox

  setup do
    root =
      Path.join(System.tmp_dir!(), "mn-prepared-worker-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "starts the same stopped prepared container before returning it", %{root: root} do
    {config, calls} = docker(root, "exited")

    assert {:ok, %{"container_name" => "owned-worker"}} =
             DockerJobSandbox.ensure("job", "prepared:latest", config)

    assert File.read!(calls) ==
             "inspect --format {{.State.Status}} owned-worker\nstart owned-worker\n"
  end

  test "starts an existing created container without rebuilding it", %{root: root} do
    {config, calls} = docker(root, "created")
    assert {:ok, _} = DockerJobSandbox.ensure("job", "prepared:latest", config)
    assert File.read!(calls) =~ "start owned-worker\n"
    refute File.read!(calls) =~ "run "
  end

  test "leaves a running shared container undisturbed", %{root: root} do
    {config, calls} = docker(root, "running")
    assert {:ok, _} = DockerJobSandbox.ensure("job", "prepared:latest", config)
    assert File.read!(calls) == "inspect --format {{.State.Status}} owned-worker\n"
  end

  test "rejects a missing prepared container instead of recreating it", %{root: root} do
    {config, calls} = docker(root, "missing")

    assert {:error, %{"exit_code" => 1}} =
             DockerJobSandbox.ensure("job", "prepared:latest", config)

    assert File.read!(calls) == "inspect --format {{.State.Status}} owned-worker\n"
  end

  test "preserves explicit paused state", %{root: root} do
    {config, calls} = docker(root, "paused")
    assert {:error, reason} = DockerJobSandbox.ensure("job", "prepared:latest", config)
    assert reason =~ "paused"
    refute File.read!(calls) =~ "start "
  end

  test "reports a failed start before dispatch", %{root: root} do
    {config, _calls} = docker(root, "exited", 9)

    assert {:error, %{"exit_code" => 9, "logs" => "start failed\n"}} =
             DockerJobSandbox.ensure("job", "prepared:latest", config)
  end

  defp docker(root, state, start_code \\ 0) do
    executable = Path.join(root, "docker")
    calls = Path.join(root, "calls")

    File.write!(executable, """
    #!/bin/sh
    echo "$*" >> '#{calls}'
    case "$1" in
      inspect)
        if [ '#{state}' = missing ]; then echo 'No such container' >&2; exit 1; fi
        echo '#{state}'
        ;;
      start)
        if [ '#{start_code}' != 0 ]; then echo 'start failed' >&2; exit #{start_code}; fi
        echo owned-worker
        ;;
      *) exit 90 ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    {%{"docker_bin" => executable, "docker_worker_container_name" => "owned-worker"}, calls}
  end
end
