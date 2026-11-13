defmodule MirrorNeuron.Runner.OpenShellTest.AttemptsTest do
  use MirrorNeuron.OpenShellCase, async: false

  alias MirrorNeuron.Runner.OpenShell

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
end
