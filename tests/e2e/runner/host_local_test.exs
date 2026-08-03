defmodule MirrorNeuron.Runner.HostLocalTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.HostLocal

  setup_all do
    if is_nil(Process.whereis(MirrorNeuron.Runner.HostProcessRegistry)) do
      start_supervised!(
        {Registry, keys: :duplicate, name: MirrorNeuron.Runner.HostProcessRegistry}
      )
    end

    :ok
  end

  test "list_all_files includes hidden runtime payload directories" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_hidden_files_test_#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(tmp_dir, ".mn-local-skills/evidence_engine_skill/src"))

      File.write!(
        Path.join(tmp_dir, ".mn-local-skills/evidence_engine_skill/src/__init__.py"),
        ""
      )

      File.write!(Path.join(tmp_dir, "visible.txt"), "ok")

      assert HostLocal.list_all_files(tmp_dir) == [
               ".mn-local-skills/evidence_engine_skill/src/__init__.py",
               "visible.txt"
             ]
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "returns an actionable error when the configured executable is absent" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_missing_executable_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    missing_executable = "mn-definitely-missing-executable"

    try do
      File.mkdir_p!(upload_dir)

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => [missing_executable]
      }

      assert {:error, reason} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-missing-executable",
                 agent_id: "agent-missing-executable",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert reason =~ "host-local executable not found: #{missing_executable}"
      assert reason =~ "Core runtime image"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "executes a bundle-local command resolved from the staged workdir" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_relative_executable_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    executable = Path.join(upload_dir, "run-worker")

    try do
      File.mkdir_p!(upload_dir)
      File.write!(executable, "#!/bin/sh\nprintf 'bundle-local-ok\\n'\n")
      File.chmod!(executable, 0o755)

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["./run-worker"]
      }

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-relative-executable",
                 agent_id: "agent-relative-executable",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert result["exit_code"] == 0
      assert result["stdout"] =~ "bundle-local-ok"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "executes a console script from a prepared python environment" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_prepared_console_script_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    python_env_dir = Path.join(tmp_dir, "prepared-python-environment")
    console_script = "mn-test-prepared-console-script"
    console_script_path = Path.join([python_env_dir, "bin", console_script])
    old_native_prep = System.get_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP")

    try do
      File.mkdir_p!(upload_dir)
      File.mkdir_p!(Path.dirname(console_script_path))
      File.write!(console_script_path, "#!/bin/sh\nprintf 'prepared-console-script-ok\\n'\n")
      File.chmod!(console_script_path, 0o755)
      System.delete_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP")

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => [console_script],
        "python_environment" => %{
          "packages" => ["mn-test-prepared-console-script==1.0.0"],
          "path" => python_env_dir
        }
      }

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-prepared-console-script",
                 agent_id: "agent-prepared-console-script",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert result["exit_code"] == 0
      assert result["stdout"] =~ "prepared-console-script-ok"
    after
      restore_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP", old_native_prep)
      File.rm_rf!(tmp_dir)
    end
  end

  test "parses structured agent event stdout lines without keeping them in stdout" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_agent_event_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/events.py"),
        """
        import json
        print("__MN_EVENT__" + json.dumps({
            "type": "tool_call_completed",
            "payload": {
                "category": "tool",
                "message": "Browsed example.com",
                "tool_name": "w3m",
                "target": "https://example.com",
                "status": "completed"
            }
        }))
        print("visible output")
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/events.py"]
      }

      parent = self()

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-agent-events",
                 agent_id: "agent-events",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir,
                 event_callback: fn event_type, payload ->
                   send(parent, {:runner_event, event_type, payload})
                 end
               )

      assert result["stdout"] =~ "visible output"
      refute result["stdout"] =~ "__MN_EVENT__"

      assert_receive {:runner_event, "tool_call_completed",
                      %{
                        "category" => "tool",
                        "tool_name" => "w3m",
                        "target" => "https://example.com",
                        "agent_id" => "agent-events"
                      }}
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "stages uploads and executes a command on the host runtime" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))

    File.write!(
      Path.join(upload_dir, "scripts/echo_input.py"),
      """
      import json
      import os
      from pathlib import Path

      payload = json.loads(Path(os.environ["MN_INPUT_FILE"]).read_text())
      print(json.dumps({"seen": payload["value"], "flag": os.environ["WORKER_FLAG"]}))
      """
    )

    config = %{
      "upload_path" => "bundle",
      "upload_as" => "bundle",
      "workdir" => "/sandbox/job/bundle",
      "command" => ["python3.11", "scripts/echo_input.py"],
      "environment" => %{"WORKER_FLAG" => "host-local-ok"}
    }

    assert {:ok, result} =
             HostLocal.run(
               %{"value" => "host-ok"},
               config,
               job_id: "job-1",
               agent_id: "agent-1",
               bundle_root: bundle_dir,
               payloads_path: payloads_dir
             )

    assert result["exit_code"] == 0
    assert result["runner"] == "host_local"
    assert result["stdout"] =~ "\"seen\": \"host-ok\""
    assert result["stdout"] =~ "\"flag\": \"host-local-ok\""

    File.rm_rf!(tmp_dir)
  end

  test "provides the internal Core gRPC target while preserving an explicit override" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_grpc_target_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    old_core_host = System.get_env("MN_CORE_HOST")
    old_grpc_port = System.get_env("MN_GRPC_PORT")
    old_grpc_target = System.get_env("MN_GRPC_TARGET")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/read_grpc_target.py"),
        """
        import json
        import os
        print(json.dumps({"target": os.environ["MN_GRPC_TARGET"]}))
        """
      )

      System.put_env("MN_CORE_HOST", "0.0.0.0")
      System.put_env("MN_GRPC_PORT", "50123")
      System.delete_env("MN_GRPC_TARGET")

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/read_grpc_target.py"]
      }

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-host-local-grpc-target",
                 agent_id: "grpc-target-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert Jason.decode!(String.trim(result["stdout"])) == %{
               "target" => "127.0.0.1:50123"
             }

      explicit_config =
        Map.put(config, "environment", %{"MN_GRPC_TARGET" => "core.internal:55555"})

      assert {:ok, explicit_result} =
               HostLocal.run(
                 %{},
                 explicit_config,
                 job_id: "job-host-local-explicit-grpc-target",
                 agent_id: "explicit-grpc-target-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert Jason.decode!(String.trim(explicit_result["stdout"])) == %{
               "target" => "core.internal:55555"
             }
    after
      restore_env("MN_CORE_HOST", old_core_host)
      restore_env("MN_GRPC_PORT", old_grpc_port)
      restore_env("MN_GRPC_TARGET", old_grpc_target)
      File.rm_rf!(tmp_dir)
    end
  end

  test "runs the default no-command heredoc through the capture wrapper" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_default_command_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")

    try do
      File.mkdir_p!(payloads_dir)

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 %{},
                 job_id: "job-default-command",
                 agent_id: "agent-default-command",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert result["exit_code"] == 0
      assert result["stdout"] =~ "No command configured for host-local worker"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "installs blueprint python requirements into a cached virtualenv" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_python_env_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    env_root = Path.join(tmp_dir, "python_envs")
    wheel_path = Path.join(tmp_dir, "mn_test_pkg-0.1-py3-none-any.whl")
    old_env_root = System.get_env("MN_BLUEPRINT_PYTHON_ENVS_DIR")
    old_native_prep = System.get_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))
      create_test_wheel(wheel_path)
      File.write!(Path.join(upload_dir, "requirements.txt"), "#{wheel_path}\n")

      File.write!(
        Path.join(upload_dir, "scripts/read_package.py"),
        """
        import json
        import os
        import sys
        import mn_test_pkg

        print(json.dumps({
            "value": mn_test_pkg.VALUE,
            "mn_python_env": os.environ["MN_PYTHON_ENV"],
            "virtual_env": os.environ["VIRTUAL_ENV"],
            "prefix": sys.prefix,
        }))
        """
      )

      System.put_env("MN_BLUEPRINT_PYTHON_ENVS_DIR", env_root)
      System.put_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP", "1")

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/read_package.py"],
        "environment" => %{"MN_BLUEPRINT_ID" => "test_python_env_blueprint"},
        "python_environment" => %{
          "requirements" => "bundle/requirements.txt"
        }
      }

      assert {:ok, first_result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-python-env",
                 agent_id: "agent-python-env",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert {:ok, second_result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-python-env",
                 agent_id: "agent-python-env",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      first_payload = Jason.decode!(String.trim(first_result["stdout"]))
      second_payload = Jason.decode!(String.trim(second_result["stdout"]))

      assert first_payload["value"] == "from-wheel"

      assert normalized_path(first_payload["mn_python_env"]) ==
               normalized_path(first_payload["virtual_env"])

      assert normalized_path(first_payload["mn_python_env"]) ==
               normalized_path(first_payload["prefix"])

      assert first_payload["mn_python_env"] == second_payload["mn_python_env"]
      assert String.starts_with?(first_payload["mn_python_env"], env_root)
      assert File.exists?(Path.join(first_payload["mn_python_env"], ".ready"))

      metadata =
        first_payload["mn_python_env"]
        |> Path.join(".mn-blueprint-resource.json")
        |> File.read!()
        |> Jason.decode!()

      assert metadata["resource_type"] == "python_venv"
      assert metadata["blueprint_id"] == "test_python_env_blueprint"
      assert metadata["requirements"]["path"] == "bundle/requirements.txt"
    after
      restore_env("MN_BLUEPRINT_PYTHON_ENVS_DIR", old_env_root)
      restore_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP", old_native_prep)
      File.rm_rf!(tmp_dir)
    end
  end

  test "rejects missing and escaping python_environment requirements files" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_python_env_error_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/noop.py"),
        """
        print("noop")
        """
      )

      base_config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/noop.py"]
      }

      missing_config =
        Map.put(base_config, "python_environment", %{"requirements" => "bundle/missing.txt"})

      assert {:error, missing_reason} =
               HostLocal.run(
                 %{},
                 missing_config,
                 job_id: "job-python-env-missing",
                 agent_id: "agent-python-env-missing",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert missing_reason =~ "requirements file is not readable"

      escaping_config =
        Map.put(base_config, "python_environment", %{"requirements" => "../requirements.txt"})

      assert {:error, escaping_reason} =
               HostLocal.run(
                 %{},
                 escaping_config,
                 job_id: "job-python-env-escape",
                 agent_id: "agent-python-env-escape",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert escaping_reason =~ "requirements must be a relative path inside payloads"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "times out long-running commands" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_timeout_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))

    File.write!(
      Path.join(upload_dir, "scripts/sleep.py"),
      """
      import time
      time.sleep(2)
      print("late")
      """
    )

    config = %{
      "upload_path" => "bundle",
      "upload_as" => "bundle",
      "workdir" => "/sandbox/job/bundle",
      "command" => ["python3.11", "scripts/sleep.py"],
      "timeout_seconds" => 0.1
    }

    assert {:error, %{"error" => "host local command timed out"}} =
             HostLocal.run(
               %{},
               config,
               job_id: "job-timeout",
               agent_id: "agent-timeout",
               bundle_root: bundle_dir,
               payloads_path: payloads_dir
             )

    File.rm_rf!(tmp_dir)
  end

  test "terminates the owned command when the runner owner exits" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_owner_exit_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    pid_path = Path.join(tmp_dir, "command.pid")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/wait.py"),
        """
        import os
        import time
        from pathlib import Path

        Path(os.environ["PID_FILE"]).write_text(str(os.getpid()))
        time.sleep(60)
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/wait.py"],
        "environment" => %{"PID_FILE" => pid_path}
      }

      task =
        Task.async(fn ->
          HostLocal.run(
            %{},
            config,
            job_id: "job-owner-exit",
            agent_id: "owner-exit-worker",
            bundle_root: bundle_dir,
            payloads_path: payloads_dir
          )
        end)

      assert wait_until(fn -> File.exists?(pid_path) end)
      pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()
      assert os_process_alive?(pid)

      assert nil == Task.shutdown(task, :brutal_kill)
      assert wait_until(fn -> not os_process_alive?(pid) end)
    after
      terminate_recorded_process(pid_path)
      File.rm_rf!(tmp_dir)
    end
  end

  test "terminates a running command when its job is cancelled" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_job_cancel_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    pid_path = Path.join(tmp_dir, "command.pid")
    job_id = "job-host-local-cancel"
    python = System.find_executable("python3") || System.find_executable("python3.11")
    original_path = System.get_env("PATH")
    assert is_binary(python)

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))
      signal_bin = Path.join(tmp_dir, "signal-bin")
      File.mkdir_p!(signal_bin)
      File.ln_s!(python, Path.join(signal_bin, "python3"))
      System.put_env("PATH", signal_bin)

      File.write!(
        Path.join(upload_dir, "scripts/wait.py"),
        """
        import os
        import time
        from pathlib import Path

        Path(os.environ["PID_FILE"]).write_text(str(os.getpid()))
        time.sleep(60)
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => [python, "scripts/wait.py"],
        "environment" => %{"PID_FILE" => pid_path}
      }

      task =
        Task.async(fn ->
          HostLocal.run(
            %{},
            config,
            job_id: job_id,
            agent_id: "cancelled-worker",
            bundle_root: bundle_dir,
            payloads_path: payloads_dir
          )
        end)

      assert wait_until(fn -> File.exists?(pid_path) end)
      pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()
      assert python_process_alive?(python, pid)

      assert :ok = HostLocal.terminate_job(job_id)
      assert {:error, "host local command cancelled"} = Task.await(task)
      assert wait_until(fn -> not python_process_alive?(python, pid) end)
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      terminate_recorded_process(pid_path)
      File.rm_rf!(tmp_dir)
    end
  end

  test "emits runtime liveness beacons while host command is alive" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_runtime_beacon_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/sleep_then_done.py"),
        """
        import time
        time.sleep(0.08)
        print("done")
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/sleep_then_done.py"],
        "beacon_enabled" => true,
        "beacon_interval_ms" => 10,
        "beacon_timeout_ms" => 1000,
        "agent_beacon_required" => false
      }

      parent = self()

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-runtime-beacon",
                 agent_id: "runtime-beacon-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir,
                 event_callback: fn event_type, event_payload ->
                   send(parent, {:beacon_event, event_type, event_payload})
                 end
               )

      assert result["stdout"] =~ "done"

      assert_receive {:beacon_event, :agent_beacon,
                      %{
                        "source" => "runtime",
                        "status" => "started",
                        "agent_id" => "runtime-beacon-worker"
                      }}

      assert_receive {:beacon_event, :agent_beacon,
                      %{
                        "source" => "runtime",
                        "status" => "working",
                        "agent_id" => "runtime-beacon-worker"
                      }}

      assert_receive {:beacon_event, :agent_beacon,
                      %{
                        "source" => "runtime",
                        "status" => "completed",
                        "agent_id" => "runtime-beacon-worker"
                      }}
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "emits runtime liveness beacons while host command produces frequent output" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_noisy_runtime_beacon_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/noisy.py"),
        """
        import time
        deadline = time.time() + 0.08
        while time.time() < deadline:
            print("tick", flush=True)
            time.sleep(0.001)
        print("done", flush=True)
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/noisy.py"],
        "beacon_enabled" => true,
        "beacon_interval_ms" => 10,
        "beacon_timeout_ms" => 1000,
        "agent_beacon_required" => false
      }

      parent = self()

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-noisy-runtime-beacon",
                 agent_id: "noisy-runtime-beacon-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir,
                 event_callback: fn event_type, event_payload ->
                   send(parent, {:beacon_event, event_type, event_payload})
                 end
               )

      assert result["stdout"] =~ "done"

      assert_receive {:beacon_event, :agent_beacon,
                      %{"source" => "runtime", "status" => "working"}}
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "parses agent beacon lines and strips them from captured stdout" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_agent_beacon_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/emit_beacon.py"),
        """
        import json
        import os

        prefix = os.environ["MN_AGENT_BEACON_STDOUT_PREFIX"]
        print(prefix + json.dumps({"message": "custom unit of work", "progress": 0.42}), flush=True)
        print(json.dumps({"ok": True}), flush=True)
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/emit_beacon.py"],
        "beacon_enabled" => true,
        "beacon_interval_ms" => 1000,
        "beacon_timeout_ms" => 1000,
        "agent_beacon_required" => true
      }

      parent = self()

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-agent-beacon",
                 agent_id: "agent-beacon-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir,
                 event_callback: fn event_type, event_payload ->
                   send(parent, {:beacon_event, event_type, event_payload})
                 end
               )

      assert result["stdout"] =~ ~s({"ok": true})
      refute result["stdout"] =~ "__MN_AGENT_BEACON__"
      refute result["raw_output"] =~ "__MN_AGENT_BEACON__"

      assert_receive {:beacon_event, :agent_beacon,
                      %{
                        "source" => "agent",
                        "status" => "working",
                        "message" => "custom unit of work",
                        "progress" => 0.42,
                        "agent_id" => "agent-beacon-worker"
                      }}
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "missed required agent beacon closes the command with retryable timeout-style error" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_missed_beacon_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/quiet.py"),
        """
        import time
        time.sleep(0.2)
        print("late")
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.11", "scripts/quiet.py"],
        "beacon_enabled" => true,
        "beacon_interval_ms" => 1000,
        "beacon_timeout_ms" => 20,
        "agent_beacon_required" => true
      }

      parent = self()

      assert {:error, %{"error" => "agent beacon deadline exceeded", "beacon" => missed_payload}} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-missed-beacon",
                 agent_id: "missed-beacon-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir,
                 event_callback: fn event_type, event_payload ->
                   send(parent, {:beacon_event, event_type, event_payload})
                 end
               )

      assert missed_payload["source"] == "agent"
      assert missed_payload["status"] == "missed"
      assert missed_payload["agent_id"] == "missed-beacon-worker"

      assert_receive {:beacon_event, :agent_beacon_missed,
                      %{
                        "source" => "agent",
                        "status" => "missed",
                        "agent_id" => "missed-beacon-worker"
                      }}
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp create_test_wheel(path) do
    files = [
      {~c"mn_test_pkg/__init__.py", "VALUE = 'from-wheel'\n"},
      {~c"mn_test_pkg-0.1.dist-info/METADATA",
       "Metadata-Version: 2.1\nName: mn-test-pkg\nVersion: 0.1\n"},
      {~c"mn_test_pkg-0.1.dist-info/WHEEL",
       "Wheel-Version: 1.0\nGenerator: mirror-neuron-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n"},
      {~c"mn_test_pkg-0.1.dist-info/RECORD",
       "mn_test_pkg/__init__.py,,\nmn_test_pkg-0.1.dist-info/METADATA,,\nmn_test_pkg-0.1.dist-info/WHEEL,,\nmn_test_pkg-0.1.dist-info/RECORD,,\n"}
    ]

    {:ok, _path} = :zip.create(String.to_charlist(path), files)
  end

  defp normalized_path(path), do: String.replace_prefix(path, "/private/var/", "/var/")

  defp wait_until(predicate, attempts \\ 100)

  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      true
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  defp wait_until(_predicate, 0), do: false

  defp os_process_alive?(pid) do
    case System.find_executable("kill") do
      nil ->
        false

      executable ->
        {_output, status} =
          System.cmd(executable, ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

        status == 0
    end
  end

  defp python_process_alive?(python, pid) do
    {_output, status} =
      System.cmd(
        python,
        ["-c", "import os,sys; os.kill(int(sys.argv[1]), 0)", Integer.to_string(pid)],
        stderr_to_stdout: true
      )

    status == 0
  end

  defp terminate_recorded_process(pid_path) do
    with true <- File.exists?(pid_path),
         {pid, ""} <- pid_path |> File.read!() |> String.trim() |> Integer.parse(),
         executable when is_binary(executable) <- System.find_executable("kill") do
      _ = System.cmd(executable, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
