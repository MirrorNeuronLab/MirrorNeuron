defmodule MirrorNeuron.Runner.HostLocalTest.CancellationTest do
  use MirrorNeuron.HostLocalCase, async: false

  alias MirrorNeuron.Runner.HostLocal

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
      "command" => ["python3.12", "scripts/sleep.py"],
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

  test "terminates the owned command when the runner owner exits" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_owner_exit_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    pid_path = Path.join(tmp_dir, "command.pid")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/wait.py"),
        """
        import os
        import time
        from pathlib import Path

        Path(os.environ["PID_FILE"]).write_text(str(os.getpid()))
        time.sleep(60)
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.12", "scripts/wait.py"],
        "environment" => %{"PID_FILE" => pid_path}
      }

      task =
        Task.async(fn ->
          HostLocal.run(
            %{},
            config,
            job_id: "job-owner-exit",
            agent_id: "owner-exit-worker",
            bundle_root: bundle_dir,
            payloads_path: payloads_dir
          )
        end)

      assert wait_until(fn ->
               case File.read(pid_path) do
                 {:ok, value} -> Regex.match?(~r/\A[0-9]+\z/, String.trim(value))
                 _ -> false
               end
             end)

      pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()
      assert os_process_alive?(pid)

      assert nil == Task.shutdown(task, :brutal_kill)
      assert wait_until(fn -> not os_process_alive?(pid) end)
    after
      terminate_recorded_process(pid_path)
      File.rm_rf!(tmp_dir)
    end
  end

  test "terminates a running command when its job is cancelled" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_job_cancel_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    pid_path = Path.join(tmp_dir, "command.pid")
    job_id = "job-host-local-cancel"
    python = System.find_executable("python3") || System.find_executable("python3.12")
    original_path = System.get_env("PATH")
    assert is_binary(python)

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))
      signal_bin = Path.join(tmp_dir, "signal-bin")
      File.mkdir_p!(signal_bin)
      File.ln_s!(python, Path.join(signal_bin, "python3"))
      System.put_env("PATH", signal_bin)

      File.write!(
        Path.join(upload_dir, "scripts/wait.py"),
        """
        import os
        import time
        from pathlib import Path

        Path(os.environ["PID_FILE"]).write_text(str(os.getpid()))
        time.sleep(60)
        """
      )

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => [python, "scripts/wait.py"],
        "environment" => %{"PID_FILE" => pid_path}
      }

      task =
        Task.async(fn ->
          HostLocal.run(
            %{},
            config,
            job_id: job_id,
            agent_id: "cancelled-worker",
            bundle_root: bundle_dir,
            payloads_path: payloads_dir
          )
        end)

      assert wait_until(fn ->
               case File.read(pid_path) do
                 {:ok, value} -> Regex.match?(~r/\A[0-9]+\z/, String.trim(value))
                 _ -> false
               end
             end)

      pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()
      assert python_process_alive?(python, pid)

      assert :ok = HostLocal.terminate_job(job_id)
      assert {:error, "host local command cancelled"} = Task.await(task)
      assert wait_until(fn -> not python_process_alive?(python, pid) end)
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      terminate_recorded_process(pid_path)
      File.rm_rf!(tmp_dir)
    end
  end
end
