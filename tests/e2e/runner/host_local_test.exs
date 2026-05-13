defmodule MirrorNeuron.Runner.HostLocalTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.HostLocal

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
      "command" => ["python3", "scripts/echo_input.py"],
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

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3", "scripts/read_package.py"],
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
        "command" => ["python3", "scripts/noop.py"]
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
      "command" => ["python3", "scripts/sleep.py"],
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

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
