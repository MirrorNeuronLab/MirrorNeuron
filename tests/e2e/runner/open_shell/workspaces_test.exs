defmodule MirrorNeuron.Runner.OpenShellTest.WorkspacesTest do
  use MirrorNeuron.OpenShellCase, async: false

  alias MirrorNeuron.Runner.OpenShell
  alias MirrorNeuron.Sandbox.OpenShellJobSandbox

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
      if os.environ.get("MN_JOB_OUTPUT_DIR"):
          output = Path(os.environ["MN_JOB_OUTPUT_DIR"])
          output.mkdir(parents=True, exist_ok=True)
          (output / "result.txt").write_text(payload["value"])
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
        python3.12 - "$script" "$root" <<'PY'
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
        download)
          root="$(sandbox_root "$3")"
          source="$root${4#/sandbox}"
          cp -R "$source/." "$5/"
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
        rewritten="$(python3.12 - "$script" "$root" <<'PY'
      import sys
      print(sys.argv[1].replace("/sandbox", sys.argv[2]))
      PY
      )"
        exec bash -lc "$rewritten"
      fi

      if [ "$1" = "rm" ] && [ "$2" = "-rf" ] && [ "$3" = "--" ]; then
        exec rm -rf -- "$root${4#/sandbox}"
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
      "sandbox_name" => "prepared-shared-test",
      "reuse_shared_sandbox" => true
    }

    env_backup = %{
      "FAKE_SANDBOXES_DIR" => System.get_env("FAKE_SANDBOXES_DIR"),
      "FAKE_DELETED_LOG" => System.get_env("FAKE_DELETED_LOG"),
      "MN_SHARED_STORAGE_ROOT" => System.get_env("MN_SHARED_STORAGE_ROOT")
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
      assert File.read!(args_log) =~ "sandbox upload prepared-shared-test"

      assert {:error, reason} =
               OpenShell.run(%{}, Map.put(config, "sync_shared_storage", true),
                 job_id: "job-shared-1"
               )

      assert reason =~ "unsupported"

      assert :ok = OpenShellJobSandbox.cleanup_job_local("job-shared-1")
      assert File.exists?(Path.join(sandboxes_dir, result1["sandbox_name"]))
      refute File.exists?(deleted_log)
    after
      Enum.each(env_backup, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

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
        python3.12 - "$script" "$root" <<'PY'
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
        rewritten="$(python3.12 - "$script" "$root" <<'PY'
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
      "sandbox_name" => "prepared-persistent-test",
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
end
