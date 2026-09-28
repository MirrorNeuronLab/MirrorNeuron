defmodule MirrorNeuron.Runner.DockerLifecycleTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.DockerWorker
  alias MirrorNeuron.Sandbox.DockerJobSandbox

  @moduletag skip: System.get_env("MN_TEST_DOCKER_LIFECYCLE") != "1"

  setup_all do
    container = "mn-lifecycle-test-#{System.unique_integer([:positive])}"
    image = System.get_env("MN_TEST_DOCKER_IMAGE", "python:3.11-slim")

    {_, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--name",
        container,
        "--entrypoint",
        "sleep",
        image,
        "infinity"
      ])

    on_exit(fn -> System.cmd("docker", ["rm", "-f", container]) end)
    {:ok, container: container, image: image}
  end

  test "owner death reaps its process tree and leaves another run and the container alive",
       context do
    {owner, job, pids} = start_command(context, "owner")
    {other_owner, other_job, other_pids} = start_command(context, "other")

    Process.exit(owner, :kill)
    assert :ok = DockerJobSandbox.cleanup_job_local(job)
    assert_processes_stopped(context, pids)
    assert processes_alive?(context, other_pids)

    Process.exit(other_owner, :kill)
    assert :ok = DockerJobSandbox.cleanup_job_local(other_job)
    assert_processes_stopped(context, other_pids)
    assert_container_usable(context)
  end

  test "timeout reaps descendants without deleting the prepared container", context do
    {owner, _job, pids} = start_command(context, "timeout", 1)

    assert_receive {:result, ^owner, {:error, %{"error" => "docker worker command timed out"}}},
                   10_000

    assert_processes_stopped(context, pids)
    assert_container_usable(context)
  end

  test "job cleanup waits for in-flight Docker commands to stop", context do
    {owner, job, pids} = start_command(context, "cancel")
    assert :ok = DockerJobSandbox.cleanup_job_local(job)

    assert_receive {:result, ^owner, {:error, %{"error" => "docker worker command interrupted"}}},
                   10_000

    assert_processes_stopped(context, pids)
    assert_container_usable(context)
  end

  defp start_command(context, label, timeout \\ 60) do
    test = self()
    job = "docker-lifecycle-#{label}-#{System.unique_integer([:positive])}"

    script = """
    import json, os, subprocess, sys, time
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'])
    print('__MN_EVENT__' + json.dumps({'type': 'test_process_started', 'payload': {'pids': [os.getpid(), child.pid]}}), flush=True)
    time.sleep(300)
    """

    owner =
      spawn(fn ->
        result =
          DockerWorker.run(
            %{},
            %{
              "image" => context.image,
              "docker_worker_container_name" => context.container,
              "command" => ["python3", "-c", script],
              "timeout_seconds" => timeout
            },
            job_id: job,
            agent_id: label,
            event_callback: fn type, payload ->
              send(test, {:event, job, type, payload})
            end
          )

        send(test, {:result, self(), result})
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      DockerJobSandbox.cleanup_job_local(job)
    end)

    assert_receive {:event, ^job, "test_process_started", %{"pids" => pids}}, 10_000
    {owner, job, pids}
  end

  defp assert_processes_stopped(context, pids) do
    refute processes_alive?(context, pids)
  end

  defp processes_alive?(context, pids) do
    script = """
    import os, sys
    alive = []
    for pid in sys.argv[1:]:
        try:
            with open('/proc/' + pid + '/stat') as record:
                alive.append(record.read().split(') ')[1].split()[0] != 'Z')
        except FileNotFoundError:
            alive.append(False)
    sys.exit(0 if any(alive) else 1)
    """

    {_, code} =
      System.cmd("docker", [
        "exec",
        context.container,
        "python3",
        "-c",
        script | Enum.map(pids, &to_string/1)
      ])

    code == 0
  end

  defp assert_container_usable(context) do
    assert {"resumed\n", 0} =
             System.cmd("docker", ["exec", context.container, "python3", "-c", "print('resumed')"])
  end
end
