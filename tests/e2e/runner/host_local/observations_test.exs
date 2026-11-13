defmodule MirrorNeuron.Runner.HostLocalTest.ObservationsTest do
  use MirrorNeuron.HostLocalCase, async: false

  alias MirrorNeuron.Runner.HostLocal

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
        "command" => ["python3.12", "scripts/events.py"]
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
        "command" => ["python3.12", "scripts/sleep_then_done.py"],
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
        "command" => ["python3.12", "scripts/noisy.py"],
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
        print(prefix + json.dumps({"message": "custom unit of work", "progress": 0.42,
            "progress_sequence": 7, "pid": os.getpid(), "wait_id": "review-1",
            "wait_timeout_ms": 3600000}), flush=True)
        print(json.dumps({"ok": True}), flush=True)
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.12", "scripts/emit_beacon.py"],
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
                        "progress_sequence" => 7,
                        "wait_id" => "review-1",
                        "wait_timeout_ms" => 3_600_000,
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
        "command" => ["python3.12", "scripts/quiet.py"],
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
end
