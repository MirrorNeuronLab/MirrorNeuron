defmodule MirrorNeuron.Runner.DockerWorkerTest.ExecutionTest do
  use MirrorNeuron.DockerWorkerCase, async: false

  alias MirrorNeuron.Runner.DockerWorker

  test "rejects a prepared image without process supervision before launching work", %{
    tmp_dir: tmp_dir
  } do
    fake_docker = Path.join(tmp_dir, "missing-python")
    write_prepared_docker(fake_docker, "#!/bin/sh\necho 'python3 not found'\nexit 127\n")
    File.chmod!(fake_docker, 0o755)

    assert {:error, reason} =
             DockerWorker.run(
               %{},
               %{
                 "image" => "worker:latest",
                 "docker_bin" => fake_docker,
                 "command" => ["sh", "-c", "sleep 300"]
               },
               job_id: "missing-python",
               agent_id: "worker"
             )

    assert reason =~ "requires Python 3 process supervision"
  end

  test "runs in an SDK-prepared worker without publishing host ports", %{
    tmp_dir: tmp_dir,
    prepared_container: prepared_container
  } do
    fake_docker = Path.join(tmp_dir, "fake-docker")
    args_log = Path.join(tmp_dir, "args.log")

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
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

  test "live preparation and progress receipts survive Docker's own soft deadline", %{
    tmp_dir: tmp_dir
  } do
    fake = Path.join(tmp_dir, "progress-docker")
    python = System.find_executable("python3")

    write_prepared_docker(fake, """
    #!/bin/sh
    if [ "$1" = exec ] && [ "$2" = -w ]; then
      exec #{python} -u - <<'PY'
    import json, time
    def preparation(kind):
        print('__MN_EVENT__'+json.dumps({"type":"runtime_preparation_"+kind,
          "payload":{"attempt_id":"actual-attempt","preparation_id":"model","kind":"model","timeout_ms":5000}}), flush=True)
    preparation('started')
    time.sleep(1.2)
    preparation('finished')
    for n in range(12):
        print('__MN_AGENT_BEACON__'+json.dumps({"source":"agent","pid":7,"progress_sequence":n}), flush=True)
        time.sleep(.1)
    print('finished')
    PY
    fi
    exit 0
    """)

    File.chmod!(fake, 0o755)
    cleanup_docker_job_on_exit("progress-job", fake)

    message =
      MirrorNeuron.Message.new("progress-job", "source", "worker", "input", %{},
        headers: %{
          "mn.workflow.attempt_id" => "actual-attempt",
          "mn.workflow.step_id" => "logical-step"
        }
      )

    config = %{
      "image" => "prepared:latest",
      "docker_bin" => fake,
      "command" => ["true"],
      "timeout_seconds" => 0.5
    }

    assert {:ok, result} =
             DockerWorker.run(%{}, config,
               job_id: "progress-job",
               agent_id: "worker",
               message: message
             )

    assert result["stdout"] =~ "finished"
    refute result["stdout"] =~ "__MN_"
  end
end
