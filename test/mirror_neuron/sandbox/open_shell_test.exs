defmodule MirrorNeuron.Sandbox.OpenShellTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Sandbox.JobSandbox
  alias MirrorNeuron.Sandbox.OpenShell

  test "stages uploads and executes a command through the configured sandbox cli" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    remote_dir = Path.join(tmp_dir, "remote_job")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))

    File.write!(
      Path.join(upload_dir, "scripts/echo_input.py"),
      """
      import json
      import os
      from pathlib import Path

      payload = json.loads(Path(os.environ["MIRROR_NEURON_INPUT_FILE"]).read_text())
      print(json.dumps({"seen": payload["value"]}))
      """
    )

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      upload_spec=""
      args=("$@")
      i=0
      while [ "$i" -lt "$#" ]; do
        current="${args[$i]}"
        if [ "$current" = "--upload" ]; then
          i=$((i + 1))
          upload_spec="${args[$i]}"
        elif [ "$current" = "--" ]; then
          break
        fi
        i=$((i + 1))
      done

      local_path="${upload_spec%%:*}"
      remote_path="${upload_spec#*:}"
      rm -rf "$remote_path"
      mkdir -p "$remote_path"
      cp -R "$local_path"/. "$remote_path"

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
      "command" => ["python3", "scripts/echo_input.py"],
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

    File.rm_rf!(tmp_dir)
  end

  test "uses a distinct sandbox name for each retry attempt" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_attempt_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    remote_dir = Path.join(tmp_dir, "remote_job")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))

    File.write!(
      Path.join(upload_dir, "scripts/echo_attempt.py"),
      """
      print("ok")
      """
    )

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      upload_spec=""
      args=("$@")
      i=0
      while [ "$i" -lt "$#" ]; do
        current="${args[$i]}"
        if [ "$current" = "--upload" ]; then
          i=$((i + 1))
          upload_spec="${args[$i]}"
        elif [ "$current" = "--" ]; then
          break
        fi
        i=$((i + 1))
      done

      local_path="${upload_spec%%:*}"
      remote_path="${upload_spec#*:}"
      rm -rf "$remote_path"
      mkdir -p "$remote_path"
      cp -R "$local_path"/. "$remote_path"

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
      "command" => ["python3", "scripts/echo_attempt.py"],
      "no_keep" => true,
      "no_auto_providers" => true,
      "tty" => false,
      "name_prefix" => "retry-test-name-prefix-that-is-deliberately-long"
    }

    assert {:ok, result1} =
             OpenShell.run(
               %{"value" => 1},
               config,
               job_id: "job-attempt-with-a-very-long-identifier-that-forces-truncation",
               agent_id: "agent-attempt-with-a-very-long-identifier-too",
               attempt: 1,
               bundle_root: bundle_dir,
               payloads_path: payloads_dir
             )

    assert {:ok, result2} =
             OpenShell.run(
               %{"value" => 1},
               config,
               job_id: "job-attempt-with-a-very-long-identifier-that-forces-truncation",
               agent_id: "agent-attempt-with-a-very-long-identifier-too",
               attempt: 2,
               bundle_root: bundle_dir,
               payloads_path: payloads_dir
             )

    assert result1["sandbox_name"] != result2["sandbox_name"]
    assert result1["sandbox_name"] =~ "a1"
    assert result2["sandbox_name"] =~ "a2"
    assert String.length(result1["sandbox_name"]) <= 63
    assert String.length(result2["sandbox_name"]) <= 63

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

      message = json.loads(Path(os.environ["MIRROR_NEURON_MESSAGE_FILE"]).read_text())
      body = Path(os.environ["MIRROR_NEURON_BODY_FILE"]).read_text()
      print(json.dumps({
          "schema_ref": message["headers"]["schema_ref"],
          "stream_id": message["stream"]["stream_id"],
          "body": body,
          "content_type": os.environ["MIRROR_NEURON_BODY_CONTENT_TYPE"]
      }))
      """
    )

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      upload_spec=""
      args=("$@")
      i=0
      while [ "$i" -lt "$#" ]; do
        current="${args[$i]}"
        if [ "$current" = "--upload" ]; then
          i=$((i + 1))
          upload_spec="${args[$i]}"
        elif [ "$current" = "--" ]; then
          break
        fi
        i=$((i + 1))
      done

      local_path="${upload_spec%%:*}"
      remote_path="${upload_spec#*:}"
      rm -rf "$remote_path"
      mkdir -p "$remote_path"
      cp -R "$local_path"/. "$remote_path"

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
      "command" => ["python3", "scripts/read_message.py"],
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

  test "reuses one shared sandbox per job and deletes it on cleanup" do
    Application.ensure_all_started(:mirror_neuron)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_shared_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    sandboxes_dir = Path.join(tmp_dir, "sandboxes")
    deleted_log = Path.join(tmp_dir, "deleted.log")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")
    fake_ssh = Path.join(tmp_dir, "fake_ssh.sh")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))
    File.mkdir_p!(sandboxes_dir)

    File.write!(
      Path.join(upload_dir, "scripts/echo_input.py"),
      """
      import json
      import os
      from pathlib import Path

      payload = json.loads(Path(os.environ["MIRROR_NEURON_INPUT_FILE"]).read_text())
      print(json.dumps({"seen": payload["value"]}))
      """
    )

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      sandbox_root() {
        local name="$1"
        printf "%s/%s" "$FAKE_SANDBOXES_DIR" "$name"
      }

      rewrite_script() {
        local script="$1"
        local root="$2"
        python3 - "$script" "$root" <<'PY'
      import sys
      print(sys.argv[1].replace("/sandbox", sys.argv[2]))
      PY
      }

      subcommand="$2"
      case "$subcommand" in
        get)
          name="$3"
          test -d "$(sandbox_root "$name")"
          ;;
        create)
          name=""
          args=("$@")
          i=2
          while [ "$i" -lt "$#" ]; do
            current="${args[$i]}"
            if [ "$current" = "--name" ]; then
              i=$((i + 1))
              name="${args[$i]}"
            elif [ "$current" = "--" ]; then
              break
            fi
            i=$((i + 1))
          done
          root="$(sandbox_root "$name")"
          mkdir -p "$root"
          shift $((i + 1))
          if [ "$#" -gt 0 ]; then
            if [ "$1" = "bash" ] && [ "$2" = "-lc" ]; then
              script="$(rewrite_script "$3" "$root")"
              exec bash -lc "$script"
            else
              exec "$@"
            fi
          fi
          ;;
        upload)
          name="$3"
          local_path="$4"
          dest="${5:-/sandbox}"
          root="$(sandbox_root "$name")"
          if [ "$dest" = "/sandbox" ]; then
            target="$root"
          else
            target="$root${dest#/sandbox}"
          fi
          rm -rf "$target"
          mkdir -p "$target"
          cp -R "$local_path"/. "$target"
          ;;
        ssh-config)
          name="$3"
          cat <<EOF
      Host openshell-$name
      User sandbox
      StrictHostKeyChecking no
      EOF
          ;;
        delete)
          shift 2
          for name in "$@"; do
            printf "%s\\n" "$name" >> "$FAKE_DELETED_LOG"
            rm -rf "$(sandbox_root "$name")"
          done
          ;;
        *)
          echo "unsupported fake openshell subcommand: $subcommand" >&2
          exit 2
          ;;
      esac
      """
    )

    File.write!(
      fake_ssh,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      cfg=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -F)
            cfg="$2"
            shift 2
            ;;
          *)
            break
            ;;
        esac
      done

      host="$1"
      shift
      sandbox_name="${host#openshell-}"
      root="$FAKE_SANDBOXES_DIR/$sandbox_name"

      if [ "$1" = "bash" ] && [ "$2" = "-lc" ]; then
        script="$3"
        rewritten="$(python3 - "$script" "$root" <<'PY'
      import sys
      print(sys.argv[1].replace("/sandbox", sys.argv[2]))
      PY
      )"
        exec bash -lc "$rewritten"
      fi

      exec "$@"
      """
    )

    File.chmod!(fake_cli, 0o755)
    File.chmod!(fake_ssh, 0o755)

    config = %{
      "sandbox_cli" => fake_cli,
      "ssh_bin" => fake_ssh,
      "upload_path" => "bundle",
      "upload_as" => "bundle",
      "sandbox_upload_path" => "/sandbox/job",
      "workdir" => "/sandbox/job/bundle",
      "command" => ["python3", "scripts/echo_input.py"],
      "no_auto_providers" => true,
      "tty" => false,
      "name_prefix" => "shared-test",
      "reuse_shared_sandbox" => true
    }

    env_backup = %{
      "FAKE_SANDBOXES_DIR" => System.get_env("FAKE_SANDBOXES_DIR"),
      "FAKE_DELETED_LOG" => System.get_env("FAKE_DELETED_LOG")
    }

    try do
      System.put_env("FAKE_SANDBOXES_DIR", sandboxes_dir)
      System.put_env("FAKE_DELETED_LOG", deleted_log)

      assert {:ok, result1} =
               OpenShell.run(
                 %{"value" => "first"},
                 config,
                 job_id: "job-shared-1",
                 agent_id: "agent-1",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert {:ok, result2} =
               OpenShell.run(
                 %{"value" => "second"},
                 config,
                 job_id: "job-shared-1",
                 agent_id: "agent-2",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert result1["sandbox_name"] == result2["sandbox_name"]
      assert result1["stdout"] =~ "\"seen\": \"first\""
      assert result2["stdout"] =~ "\"seen\": \"second\""
      assert File.dir?(Path.join(sandboxes_dir, result1["sandbox_name"]))

      assert :ok = JobSandbox.cleanup_job_local("job-shared-1")
      refute File.exists?(Path.join(sandboxes_dir, result1["sandbox_name"]))
      assert File.read!(deleted_log) =~ result1["sandbox_name"]
    after
      Enum.each(env_backup, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end
  end
end
