defmodule MirrorNeuron.Runner.DockerWorkerTest.ModelsTest do
  use MirrorNeuron.DockerWorkerCase, async: false

  alias MirrorNeuron.Runner.DockerWorker

  test "uses prepared model endpoint instead of docker model cli", %{tmp_dir: tmp_dir} do
    fake_docker = Path.join(tmp_dir, "fake-docker-model-endpoint")
    args_log = Path.join(tmp_dir, "model-endpoint-args.log")

    write_prepared_docker(fake_docker, """
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

    write_prepared_docker(fake_docker, """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> #{args_log}
    printf -- '---\\n' >> #{args_log}
    if [ "$1" = "model" ]; then
      exit 9
    fi
    if [ "$1" = "exec" ] && [ "$2" = "-w" ]; then
      echo '__MN_EVENT__{"type":"runtime_model_install_started","payload":{"category":"system","message":"Installing nemotron-3.5-bolt-e4b:q4_k_m on mirror_neuron@10.0.4.27.","model":"nemotron-3.5-bolt-e4b:q4_k_m","node":"mirror_neuron@10.0.4.27","status":"started"}}'
      echo '__MN_EVENT__{"type":"runtime_model_ready","payload":{"category":"system","message":"Runtime model nemotron-3.5-bolt-e4b:q4_k_m is ready on mirror_neuron@10.0.4.27.","model":"nemotron-3.5-bolt-e4b:q4_k_m","node":"mirror_neuron@10.0.4.27","status":"installed"}}'
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
                      "model" => "nemotron-3.5-bolt-e4b:q4_k_m",
                      "node" => "mirror_neuron@10.0.4.27",
                      "message" =>
                        "Installing nemotron-3.5-bolt-e4b:q4_k_m on mirror_neuron@10.0.4.27."
                    }}

    assert_receive {:docker_event, "runtime_model_ready",
                    %{
                      "model" => "nemotron-3.5-bolt-e4b:q4_k_m",
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

    write_prepared_docker(fake_docker, """
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
    System.put_env("MN_NODE_RUNTIME_MODELS", "nemotron-3.5-bolt-e4b:q4_k_m,nemotron3")

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
end
