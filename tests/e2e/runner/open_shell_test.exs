defmodule MirrorNeuron.Runner.OpenShellTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runner.OpenShell
  alias MirrorNeuron.Sandbox.OpenShellJobSandbox

  setup do
    previous = System.get_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP")
    System.put_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP", "1")

    on_exit(fn ->
      if is_nil(previous),
        do: System.delete_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP"),
        else: System.put_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP", previous)
    end)
  end

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
      "command" => ["/usr/bin/python3", "scripts/echo_attempt.py"],
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
    policy_dir = Path.join(payloads_dir, "policies")
    sandboxes_dir = Path.join(tmp_dir, "sandboxes")
    deleted_log = Path.join(tmp_dir, "deleted.log")
    args_log = Path.join(tmp_dir, "openshell_args.log")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")
    fake_ssh = Path.join(tmp_dir, "fake_ssh.sh")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))
    File.mkdir_p!(policy_dir)
    File.mkdir_p!(sandboxes_dir)

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
        api_allowlist:
          name: api-allowlist
          endpoints:
            - host: api.example.com
              port: 443
            - host: 203.0.113.10
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

      sandbox_root() {
        local name="$1"
        printf "%s/%s" "$FAKE_SANDBOXES_DIR" "$name"
      }

      rewrite_script() {
        local script="$1"
        local root="$2"
        python3.11 - "$script" "$root" <<'PY'
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
          if [ -d "$local_path" ]; then
            mkdir -p "$target"
            cp -R "$local_path" "$target/"
          else
            mkdir -p "$(dirname "$target")"
            cp "$local_path" "$target"
          fi
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
        rewritten="$(python3.11 - "$script" "$root" <<'PY'
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
      "upload_paths" => [%{"source" => "bundle", "target" => "bundle"}],
      "sandbox_upload_path" => "/sandbox/job",
      "workdir" => "/sandbox/job/bundle",
      "command" => ["/usr/bin/python3", "scripts/echo_input.py"],
      "policy" => "policies/api-egress.yaml",
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
      policy_text = args_log |> logged_arg_after("--policy") |> File.read!()
      assert policy_text =~ "network_policies:"
      assert policy_text =~ "/dev/null"

      assert :ok = OpenShellJobSandbox.cleanup_job_local("job-shared-1")
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

  test "shared sandbox cleanup removes owned local OpenShell Docker containers when gateway delete fails" do
    Application.ensure_all_started(:mirror_neuron)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_docker_cleanup_test_#{System.unique_integer([:positive])}"
      )

    sandboxes_dir = Path.join(tmp_dir, "sandboxes")
    containers_dir = Path.join(tmp_dir, "containers")
    removed_log = Path.join(tmp_dir, "removed.log")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")
    fake_docker = Path.join(tmp_dir, "fake_docker.sh")
    job_id = "job-docker-cleanup-#{System.unique_integer([:positive])}"

    File.mkdir_p!(sandboxes_dir)
    File.mkdir_p!(containers_dir)

    File.write!(
      fake_cli,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      sandbox_root() {
        local name="$1"
        printf "%s/%s" "$FAKE_SANDBOXES_DIR" "$name"
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
          mkdir -p "$(sandbox_root "$name")"
          ;;
        delete)
          echo "gateway unavailable" >&2
          exit 1
          ;;
        *)
          echo "unsupported fake openshell subcommand: $subcommand" >&2
          exit 2
          ;;
      esac
      """
    )

    File.write!(
      fake_docker,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      command="$1"
      shift
      case "$command" in
        ps)
          for container in "$FAKE_DOCKER_CONTAINERS"/*; do
            [ -e "$container" ] || continue
            name="$(basename "$container")"
            printf "id-%s\\t%s\\n" "$name" "$name"
          done
          ;;
        rm)
          if [ "${1:-}" = "-f" ]; then
            shift
          fi
          for id in "$@"; do
            name="${id#id-}"
            printf "%s\\n" "$name" >> "$FAKE_DOCKER_REMOVED_LOG"
            rm -f "$FAKE_DOCKER_CONTAINERS/$name"
          done
          ;;
        *)
          echo "unsupported fake docker command: $command" >&2
          exit 2
          ;;
      esac
      """
    )

    File.chmod!(fake_cli, 0o755)
    File.chmod!(fake_docker, 0o755)

    config = %{
      "sandbox_cli" => fake_cli,
      "no_auto_providers" => true,
      "tty" => false,
      "reuse_shared_sandbox" => true
    }

    env_backup = %{
      "FAKE_SANDBOXES_DIR" => System.get_env("FAKE_SANDBOXES_DIR"),
      "FAKE_DOCKER_CONTAINERS" => System.get_env("FAKE_DOCKER_CONTAINERS"),
      "FAKE_DOCKER_REMOVED_LOG" => System.get_env("FAKE_DOCKER_REMOVED_LOG"),
      "MN_DOCKER_BIN" => System.get_env("MN_DOCKER_BIN")
    }

    try do
      System.put_env("FAKE_SANDBOXES_DIR", sandboxes_dir)
      System.put_env("FAKE_DOCKER_CONTAINERS", containers_dir)
      System.put_env("FAKE_DOCKER_REMOVED_LOG", removed_log)
      System.put_env("MN_DOCKER_BIN", fake_docker)

      assert {:ok, sandbox} = OpenShellJobSandbox.ensure(job_id, config)
      container_name = "openshell-#{sandbox["sandbox_name"]}-port-mapping"
      File.touch!(Path.join(containers_dir, container_name))

      assert :ok = OpenShellJobSandbox.cleanup_job_local(job_id)
      refute File.exists?(Path.join(containers_dir, container_name))
      assert File.read!(removed_log) =~ container_name

      changed_node_container_name =
        "openshell-mirror-neuron-job-#{String.downcase(job_id)}-old-node-port-mapping"

      File.touch!(Path.join(containers_dir, changed_node_container_name))
      assert :ok = OpenShellJobSandbox.cleanup_job_local(job_id, config)
      refute File.exists?(Path.join(containers_dir, changed_node_container_name))
    after
      OpenShellJobSandbox.cleanup_job_local(job_id)

      Enum.each(env_backup, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end
  end

  test "failed shared-sandbox cleanup retains its owner and configuration for retry" do
    Application.ensure_all_started(:mirror_neuron)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_cleanup_retry_#{System.unique_integer([:positive])}"
      )

    sandboxes_dir = Path.join(tmp_dir, "sandboxes")
    allow_delete = Path.join(tmp_dir, "allow-delete")
    fake_cli = Path.join(tmp_dir, "fake-openshell")
    fake_docker = Path.join(tmp_dir, "fake-docker")
    job_id = "job-openshell-cleanup-retry"
    previous_docker = System.get_env("MN_DOCKER_BIN")

    File.mkdir_p!(sandboxes_dir)

    File.write!(fake_cli, """
    #!/usr/bin/env bash
    set -euo pipefail
    command="$2"
    name="$3"
    case "$command" in
      get)
        test -d "#{sandboxes_dir}/$name"
        ;;
      create)
        name=""
        args=("$@")
        i=2
        while [ "$i" -lt "$#" ]; do
          if [ "${args[$i]}" = "--name" ]; then
            i=$((i + 1))
            name="${args[$i]}"
            break
          fi
          i=$((i + 1))
        done
        mkdir -p "#{sandboxes_dir}/$name"
        ;;
      delete)
        if [ -f "#{allow_delete}" ]; then
          rm -rf "#{sandboxes_dir}/$name"
          exit 0
        fi
        echo "sandbox is busy" >&2
        exit 9
        ;;
    esac
    """)

    File.write!(fake_docker, """
    #!/usr/bin/env bash
    if [ "$1" = "ps" ]; then
      exit 0
    fi
    exit 0
    """)

    File.chmod!(fake_cli, 0o755)
    File.chmod!(fake_docker, 0o755)
    System.put_env("MN_DOCKER_BIN", fake_docker)

    config = %{
      "sandbox_cli" => fake_cli,
      "shared_sandbox_prefix" => "custom-cleanup-prefix",
      "no_auto_providers" => true,
      "tty" => false
    }

    try do
      assert {:ok, _sandbox} = OpenShellJobSandbox.ensure(job_id, config)
      assert [{owner, _meta}] = Registry.lookup(MirrorNeuron.Sandbox.Registry, job_id)

      assert {:error, _reason} = OpenShellJobSandbox.cleanup_job_local(job_id)
      assert Process.alive?(owner)
      assert :sys.get_state(owner).config["shared_sandbox_prefix"] == "custom-cleanup-prefix"
      assert :sys.get_state(owner).cleanup_required? == true

      File.touch!(allow_delete)
      assert :ok = OpenShellJobSandbox.cleanup_job_local(job_id)
      refute Process.alive?(owner)
    after
      File.touch!(allow_delete)
      OpenShellJobSandbox.cleanup_job_local(job_id, config)

      if is_nil(previous_docker),
        do: System.delete_env("MN_DOCKER_BIN"),
        else: System.put_env("MN_DOCKER_BIN", previous_docker)

      File.rm_rf!(tmp_dir)
    end
  end

  test "persistent shared workspaces survive multiple runs for the same agent" do
    Application.ensure_all_started(:mirror_neuron)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_persistent_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    sandboxes_dir = Path.join(tmp_dir, "sandboxes")
    fake_cli = Path.join(tmp_dir, "fake_openshell.sh")
    fake_ssh = Path.join(tmp_dir, "fake_ssh.sh")

    File.mkdir_p!(Path.join(upload_dir, "scripts"))
    File.mkdir_p!(sandboxes_dir)

    File.write!(
      Path.join(upload_dir, "scripts/increment_counter.py"),
      """
      import json
      import os
      from pathlib import Path

      counter_file = Path(os.environ["MN_WORKDIR"]) / "state" / "counter.json"
      counter_file.parent.mkdir(parents=True, exist_ok=True)
      if counter_file.exists():
          payload = json.loads(counter_file.read_text())
      else:
          payload = {"count": 0}
      payload["count"] += 1
      counter_file.write_text(json.dumps(payload))
      print(json.dumps({"count": payload["count"]}))
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
        python3.11 - "$script" "$root" <<'PY'
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
          if [ -d "$local_path" ]; then
            mkdir -p "$target"
            cp -R "$local_path" "$target/"
          else
            mkdir -p "$(dirname "$target")"
            cp "$local_path" "$target"
          fi
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
            rm -rf "$(sandbox_root "$name")"
          done
          ;;
        *)
          echo "unsupported fake openshell subcommand: $subcommand" >&2
          exit 1
          ;;
      esac
      """
    )

    File.write!(
      fake_ssh,
      """
      #!/usr/bin/env bash
      set -euo pipefail

      while [ "$1" = "-F" ]; do
        shift 2
      done

      host="$1"
      shift

      sandbox_name="${host#openshell-}"
      root="$FAKE_SANDBOXES_DIR/$sandbox_name"

      if [ "$1" = "bash" ] && [ "$2" = "-lc" ]; then
        script="$3"
        rewritten="$(python3.11 - "$script" "$root" <<'PY'
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
      "command" => ["/usr/bin/python3", "scripts/increment_counter.py"],
      "no_auto_providers" => true,
      "tty" => false,
      "name_prefix" => "persistent-test",
      "reuse_shared_sandbox" => true,
      "persistent_workspace" => true
    }

    env_backup = %{"FAKE_SANDBOXES_DIR" => System.get_env("FAKE_SANDBOXES_DIR")}

    try do
      System.put_env("FAKE_SANDBOXES_DIR", sandboxes_dir)

      assert {:ok, result1} =
               OpenShell.run(
                 %{},
                 config,
                 job_id: "job-persistent-1",
                 agent_id: "region-1",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert {:ok, result2} =
               OpenShell.run(
                 %{},
                 config,
                 job_id: "job-persistent-1",
                 agent_id: "region-1",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert result1["stdout"] =~ "\"count\": 1"
      assert result2["stdout"] =~ "\"count\": 2"
      assert :ok = OpenShellJobSandbox.cleanup_job_local("job-persistent-1")
    after
      Enum.each(env_backup, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end
  end

  defp logged_arg_after(log_path, flag) do
    log_path
    |> File.read!()
    |> String.split()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _other -> nil
    end)
  end
end
