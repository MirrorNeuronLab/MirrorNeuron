defmodule MirrorNeuron.Runner.OpenShellTest.ContextTest do
  use MirrorNeuron.OpenShellCase, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runner.OpenShell

  test "stages uploads and executes a command through the configured sandbox cli" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    sandbox_image_dir = Path.join(payloads_dir, "sandbox_image")
    policy_dir = Path.join(payloads_dir, "policies")
    remote_dir = Path.join(tmp_dir, "remote_job")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")
    args_log = Path.join(tmp_dir, "openshell_args.log")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))
    File.mkdir_p!(sandbox_image_dir)
    File.mkdir_p!(policy_dir)

    File.write!(
      Path.join(upload_dir, "scripts/echo_input.py"),
      """
      import json
      import os
      from pathlib import Path

      payload = json.loads(Path(os.environ["MN_INPUT_FILE"]).read_text())
      print(json.dumps({"seen": payload["value"]}))
      """
    )

    File.write!(
      Path.join(policy_dir, "api-egress.yaml"),
      """
      version: 1
      network_policies:
        metrics_api:
          name: metrics-api
          endpoints:
            - host: api.example.com
              port: 443
          binaries:
            - path: /usr/bin/python3
      """
    )

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      printf "%s\\n" "$*" >> "#{args_log}"

      upload_specs=()
      args=("$@")
      i=0
      while [ "$i" -lt "$#" ]; do
        current="${args[$i]}"
        if [ "$current" = "--upload" ]; then
          i=$((i + 1))
          upload_specs+=("${args[$i]}")
        elif [ "$current" = "--" ]; then
          break
        fi
        i=$((i + 1))
      done

      for upload_spec in "${upload_specs[@]}"; do
        local_path="${upload_spec%%:*}"
        remote_path="${upload_spec#*:}"
        if [ -d "$local_path" ]; then
          mkdir -p "$remote_path"
          cp -R "$local_path" "$remote_path/"
        else
          mkdir -p "$(dirname "$remote_path")"
          cp "$local_path" "$remote_path"
        fi
      done

      shift $((i + 1))
      exec "$@"
      """
    )

    File.chmod!(fake_cli, 0o755)

    payload = %{"value" => "sandbox-ok"}

    config = %{
      "sandbox_cli" => fake_cli,
      "reuse_shared_sandbox" => false,
      "upload_path" => "bundle",
      "upload_as" => "bundle",
      "sandbox_upload_path" => remote_dir,
      "workdir" => Path.join(remote_dir, "bundle"),
      "command" => ["/usr/bin/python3", "scripts/echo_input.py"],
      "custom_openshell_image" => "sandbox_image",
      "policy" => "policies/api-egress.yaml",
      "no_keep" => true,
      "no_auto_providers" => true,
      "tty" => false,
      "name_prefix" => "test"
    }

    assert {:ok, result} =
             OpenShell.run(
               payload,
               config,
               job_id: "job-1",
               agent_id: "agent-1",
               bundle_root: bundle_dir,
               payloads_path: payloads_dir
             )

    assert result["exit_code"] == 0
    assert result["stdout"] =~ "\"seen\": \"sandbox-ok\""
    policy_text = args_log |> logged_arg_after("--policy") |> File.read!()
    assert policy_text =~ "network_policies:"
    assert policy_text =~ "/dev/null"
    assert File.read!(args_log) =~ "--from #{sandbox_image_dir}"

    File.rm_rf!(tmp_dir)
  end

  test "stages the full message file and raw stream body for sandbox workers" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_stream_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    remote_dir = Path.join(tmp_dir, "remote_job")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))

    File.write!(
      Path.join(upload_dir, "scripts/read_message.py"),
      """
      import json
      import os
      from pathlib import Path

      message = json.loads(Path(os.environ["MN_MESSAGE_FILE"]).read_text())
      body = Path(os.environ["MN_BODY_FILE"]).read_text()
      print(json.dumps({
          "schema_ref": message["headers"]["schema_ref"],
          "stream_id": message["stream"]["stream_id"],
          "body": body,
          "content_type": os.environ["MN_BODY_CONTENT_TYPE"]
      }))
      """
    )

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      upload_specs=()
      args=("$@")
      i=0
      while [ "$i" -lt "$#" ]; do
        current="${args[$i]}"
        if [ "$current" = "--upload" ]; then
          i=$((i + 1))
          upload_specs+=("${args[$i]}")
        elif [ "$current" = "--" ]; then
          break
        fi
        i=$((i + 1))
      done

      for upload_spec in "${upload_specs[@]}"; do
        local_path="${upload_spec%%:*}"
        remote_path="${upload_spec#*:}"
        if [ -d "$local_path" ]; then
          mkdir -p "$remote_path"
          cp -R "$local_path" "$remote_path/"
        else
          mkdir -p "$(dirname "$remote_path")"
          cp "$local_path" "$remote_path"
        fi
      done

      shift $((i + 1))
      exec "$@"
      """
    )

    File.chmod!(fake_cli, 0o755)

    config = %{
      "sandbox_cli" => fake_cli,
      "reuse_shared_sandbox" => false,
      "upload_path" => "bundle",
      "upload_as" => "bundle",
      "sandbox_upload_path" => remote_dir,
      "workdir" => Path.join(remote_dir, "bundle"),
      "command" => ["/usr/bin/python3", "scripts/read_message.py"],
      "content_type" => "application/x-ndjson",
      "no_keep" => true,
      "no_auto_providers" => true,
      "tty" => false,
      "name_prefix" => "stream-test"
    }

    message =
      Message.new(
        "job-stream",
        "router",
        "executor",
        "progress_chunk",
        [%{"checked" => 10}, %{"checked" => 20}],
        class: "stream",
        content_type: "application/x-ndjson",
        headers: %{"schema_ref" => "com.test.progress"},
        stream: %{"stream_id" => "stream-1", "seq" => 2, "open" => false, "close" => true}
      )

    assert {:ok, result} =
             OpenShell.run(
               %{"ignored" => true},
               config,
               message: message,
               job_id: "job-stream",
               agent_id: "executor",
               bundle_root: bundle_dir,
               payloads_path: payloads_dir
             )

    assert result["exit_code"] == 0
    decoded = Jason.decode!(result["stdout"])
    assert decoded["schema_ref"] == "com.test.progress"
    assert decoded["stream_id"] == "stream-1"
    assert decoded["body"] == "{\"checked\":10}\n{\"checked\":20}\n"
    assert decoded["content_type"] == "application/x-ndjson"

    File.rm_rf!(tmp_dir)
  end

  test "passes selected host environment variables through to sandbox commands" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_env_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    remote_dir = Path.join(tmp_dir, "remote_job")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))

    File.write!(
      Path.join(upload_dir, "scripts/read_env.py"),
      """
      import json
      import os

      print(json.dumps({
          "gemini_api_key": os.environ.get("GEMINI_API_KEY"),
          "mn_test_passthrough": os.environ.get("MN_TEST_PASSTHROUGH"),
          "worker_label": os.environ.get("WORKER_LABEL"),
      }))
      """
    )

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      upload_specs=()
      args=("$@")
      i=0
      while [ "$i" -lt "$#" ]; do
        current="${args[$i]}"
        if [ "$current" = "--upload" ]; then
          i=$((i + 1))
          upload_specs+=("${args[$i]}")
        elif [ "$current" = "--" ]; then
          break
        fi
        i=$((i + 1))
      done

      for upload_spec in "${upload_specs[@]}"; do
        local_path="${upload_spec%%:*}"
        remote_path="${upload_spec#*:}"
        if [ -d "$local_path" ]; then
          mkdir -p "$remote_path"
          cp -R "$local_path" "$remote_path/"
        else
          mkdir -p "$(dirname "$remote_path")"
          cp "$local_path" "$remote_path"
        fi
      done

      shift $((i + 1))
      exec "$@"
      """
    )

    File.chmod!(fake_cli, 0o755)

    System.put_env("GEMINI_API_KEY", "test-gemini-key")
    System.put_env("MN_TEST_PASSTHROUGH", "test-visible-value")

    on_exit(fn ->
      System.delete_env("GEMINI_API_KEY")
      System.delete_env("MN_TEST_PASSTHROUGH")
      File.rm_rf!(tmp_dir)
    end)

    config = %{
      "sandbox_cli" => fake_cli,
      "reuse_shared_sandbox" => false,
      "upload_path" => "bundle",
      "upload_as" => "bundle",
      "sandbox_upload_path" => remote_dir,
      "workdir" => Path.join(remote_dir, "bundle"),
      "command" => ["/usr/bin/python3", "scripts/read_env.py"],
      "pass_env" => ["GEMINI_API_KEY", "MN_TEST_PASSTHROUGH"],
      "environment" => %{"WORKER_LABEL" => "sandbox-env-test"},
      "no_keep" => true,
      "no_auto_providers" => true,
      "tty" => false,
      "name_prefix" => "env-test"
    }

    assert {:ok, result} =
             OpenShell.run(
               %{},
               config,
               job_id: "job-env-1",
               agent_id: "agent-env-1",
               bundle_root: bundle_dir,
               payloads_path: payloads_dir
             )

    assert result["exit_code"] == 0
    decoded = Jason.decode!(result["stdout"])
    assert decoded["gemini_api_key"] == "[REDACTED]"
    assert decoded["mn_test_passthrough"] == "test-visible-value"
    assert decoded["worker_label"] == "sandbox-env-test"
  end
end
