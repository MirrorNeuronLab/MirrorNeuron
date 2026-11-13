defmodule MirrorNeuron.Runner.HostLocalTest.CommandsTest do
  use MirrorNeuron.HostLocalCase, async: false

  alias MirrorNeuron.Runner.HostLocal

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

  test "executes a prepared Python console script whose shebang names the host cache path" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_host_shebang_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    python_env_dir = Path.join(tmp_dir, "prepared-python-environment")
    python_env_bin = Path.join(python_env_dir, "bin")
    console_script = "mn-test-host-shebang-console-script"
    console_script_path = Path.join(python_env_bin, console_script)
    old_native_prep = System.get_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP")

    try do
      File.mkdir_p!(upload_dir)
      {_, 0} = System.cmd(System.find_executable("python3.12"), ["-m", "venv", python_env_dir])

      File.write!(
        console_script_path,
        "#!/Users/developer/.mn/cache/blueprint-python-envs/test/bin/python\n" <>
          "print('prepared-host-shebang-console-script-ok')\n"
      )

      File.chmod!(console_script_path, 0o755)
      System.delete_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP")

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => [console_script],
        "python_environment" => %{
          "packages" => ["mn-test-host-shebang-console-script==1.0.0"],
          "path" => python_env_dir
        }
      }

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-host-shebang-console-script",
                 agent_id: "agent-host-shebang-console-script",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert result["exit_code"] == 0
      assert result["stdout"] =~ "prepared-host-shebang-console-script-ok"
    after
      restore_env("MN_CORE_ALLOW_NATIVE_RESOURCE_PREP", old_native_prep)
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
end
