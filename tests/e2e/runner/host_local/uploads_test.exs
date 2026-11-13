defmodule MirrorNeuron.Runner.HostLocalTest.UploadsTest do
  use MirrorNeuron.HostLocalCase, async: false

  alias MirrorNeuron.Runner.HostLocal

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
      "command" => ["python3.12", "scripts/echo_input.py"],
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

  test "rejects unprepared blueprint python requirements" do
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
        "command" => ["python3.12", "scripts/read_package.py"],
        "environment" => %{"MN_BLUEPRINT_ID" => "test_python_env_blueprint"},
        "python_environment" => %{
          "requirements" => "bundle/requirements.txt"
        }
      }

      assert {:error,
              "python_environment preparation is owned by mn-python-sdk/API/CLI; prepare the environment before submission and provide python_environment.path, MN_PYTHON_ENV, or VIRTUAL_ENV"} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-python-env",
                 agent_id: "agent-python-env",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )
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
        "command" => ["python3.12", "scripts/noop.py"]
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
end
