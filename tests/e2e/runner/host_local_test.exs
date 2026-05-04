defmodule MirrorNeuron.Runner.HostLocalTest do
  use ExUnit.Case, async: true

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
end
