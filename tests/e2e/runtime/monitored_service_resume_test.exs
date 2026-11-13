defmodule MirrorNeuron.Runtime.MonitoredServiceResumeTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runner.HostLocal
  alias MirrorNeuron.Runtime.RunControl

  test "explicit resume restarts a stopped native monitored service in the same run", %{
    root: root
  } do
    File.mkdir_p!(root)
    starts = Path.join(root, "service-starts")
    python = System.get_env("MN_TEST_PYTHON") || System.find_executable("python3")
    assert is_binary(python)

    # Use the real shared SDK reporter in an owned native process. Its delivery
    # remains executing when pause terminates it; readiness must cross the
    # Python event transport again before the next resume can complete.
    command = """
    import os, time
    from types import SimpleNamespace
    from mn_sdk.integrations.service_lifecycle import ServiceLifecycle
    context = SimpleNamespace(
        resources={}, environment=dict(os.environ), agent_id="monitor",
        job_id=os.environ["MN_JOB_ID"], run_id=os.environ["MN_RUN_ID"],
        step_id="service:monitor", root="service",
        store=SimpleNamespace(run_dir=os.environ["TEST_RUN_DIR"], commit=lambda *a, **kw: None),
    )
    with open(os.environ['STARTS_FILE'], 'a') as output:
        output.write(str(os.getpid()) + '\\n')
        output.flush()
    ServiceLifecycle(context).publish("serving")
    while True:
        time.sleep(0.05)
    """

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "native_monitored_service_resume",
      "type" => "service",
      "entrypoints" => ["monitor"],
      "nodes" => [
        %{
          "node_id" => "monitor",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => HostLocal,
            "command" => [python, "-c", command],
            "output_message_type" => nil,
            "environment" => %{
              "STARTS_FILE" => starts,
              "TEST_RUN_DIR" => root,
              "MN_WORKFLOW_STEP_HANDLER" => "mn_sdk.integrations.block_auxiliary",
              "MN_WORKFLOW_STEP_ID" => "service:monitor",
              "MN_WORKFLOW_STEP_WITH_JSON" =>
                Jason.encode!(%{"block_service_id" => "monitor", "revision" => "test"})
            }
          }
        }
      ],
      "edges" => []
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> length(started_pids(starts)) == 1 end, 5_000)
    coordinator = job_coordinator_pid(job_id)

    for generation <- 2..3 do
      old_pid = List.last(started_pids(starts))
      pause_id = "pause-#{generation}"
      assert {:ok, _} = RunControl.submit(job_id, "pause", pause_id)

      wait_until(
        fn ->
          match?({:ok, %{"pause_cleanup_status" => "complete"}}, RedisStore.fetch_job(job_id))
        end,
        5_000
      )

      wait_until(
        fn -> match?({:ok, %{"status" => "completed"}}, RunControl.get(job_id, pause_id)) end,
        5_000
      )

      refute MirrorNeuron.HostLocalCase.os_process_alive?(old_pid)
      resume_id = "resume-#{generation}"
      assert {:ok, _} = RunControl.submit(job_id, "resume", resume_id)

      wait_until(
        fn -> match?({:ok, %{"status" => "completed"}}, RunControl.get(job_id, resume_id)) end,
        5_000
      )

      wait_until(fn -> length(started_pids(starts)) == generation end, 5_000)
      assert job_coordinator_pid(job_id) == coordinator
      assert running_status?(job_id)
      assert MirrorNeuron.HostLocalCase.os_process_alive?(List.last(started_pids(starts)))
    end

    assert {:ok, events} = MirrorNeuron.events(job_id)
    refute Enum.any?(events, &(&1["type"] == "job_clean_restart_scheduled"))
  end

  defp started_pids(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)

      _ ->
        []
    end
  end
end
