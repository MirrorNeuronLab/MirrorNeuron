defmodule MirrorNeuron.Runtime.PauseResumeTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.RuntimeTest.SlowServiceStop
  alias MirrorNeuron.RuntimeTest.PauseResumeInvocationCounter
  alias MirrorNeuron.RuntimeTest.PauseResumeRunner

  test "queues messages while paused and completes after resume" do
    manifest = pause_resume_dag_manifest("pause_resume_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_paused?(job_id, "sink") end)
    assert_runtime_workflow_manifest(job_id)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved while paused"}
             })

    wait_until(fn -> agent_pending_count(job_id, "sink") == 1 end)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "completed"
    assert_runtime_workflow_manifest(job_id)

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert_event_before(events, "job_pausing", "job_paused")
    assert_event_before(events, "job_paused", "job_resumed")
    assert_event_before(events, "job_resumed", "job_completed")

    RedisStore.delete_job(job_id)
  end

  test "resume is idempotent for an already running job" do
    manifest = pause_resume_dag_manifest("resume_running_idempotent_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, %{"status" => "running"}} = MirrorNeuron.inspect_job(job_id)
    assert_runtime_workflow_manifest(job_id)

    cleanup_runtime_job(job_id)
  end

  test "pause is idempotent for an already paused job" do
    manifest = pause_resume_dag_manifest("pause_idempotent_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, %{"status" => "paused"}} = MirrorNeuron.inspect_job(job_id)

    cleanup_runtime_job(job_id)
  end

  test "resume rejects an unconfirmed invocation without executing its effect again" do
    PauseResumeInvocationCounter.reset()

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "pause_resume_inflight_workflow_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"work" => "resume"}]},
      "flow" => %{
        "steps" => [
          %{
            "id" => "worker",
            "run" => "worker",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 60,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
            }
          }
        ],
        "graph" => %{"edges" => []}
      },
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => PauseResumeRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        },
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "worker", "to_node" => "sink", "message_type" => "workflow_done"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)
    wait_until(fn -> PauseResumeInvocationCounter.current() == 1 end, 2_000)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    wait_until(fn -> agent_unregistered?(job_id, "worker") end, 2_000)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)
    # Delivery v2 cannot infer whether an interrupted handler committed an
    # external effect, even when the old runner declares safe_to_retry.
    assert job["status"] == "failed", inspect(job)
    assert inspect(job) =~ "invocation_outcome_unconfirmed"
    assert PauseResumeInvocationCounter.current() == 1

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert_event_before(events, "job_paused", "job_resumed")
    assert_event_before(events, "job_resumed", "job_failed")

    RedisStore.delete_job(job_id)
  end

  test "pause and resume retain exactly one coordinator health timer" do
    Application.put_env(:mirror_neuron, :job_health_check_interval_ms, 10_000)
    manifest = pause_resume_dag_manifest("pause_resume_health_timer_test")

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> running_status?(job_id) end)

    coordinator = job_coordinator_pid(job_id)
    first_ref = :sys.get_state(coordinator).health_check_timer_ref
    assert is_integer(Process.read_timer(first_ref))

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)

    second_ref = :sys.get_state(coordinator).health_check_timer_ref
    refute second_ref == first_ref
    assert Process.read_timer(first_ref) == false
    assert is_integer(Process.read_timer(second_ref))

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)
    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)

    third_ref = :sys.get_state(coordinator).health_check_timer_ref
    refute third_ref == second_ref
    assert Process.read_timer(second_ref) == false
    assert is_integer(Process.read_timer(third_ref))

    cleanup_runtime_job(job_id)
  end

  test "a slow service pause acknowledges once and gates resume on physical cleanup" do
    Process.register(self(), SlowServiceStop)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "slow_pause",
      "type" => "service",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{"runner_module" => SlowServiceStop}
        }
      ],
      "edges" => []
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    on_exit(fn -> MirrorNeuron.cancel(job_id) end)
    wait_until(fn -> running_status?(job_id) end)
    assert {:ok, "pause_pending"} = MirrorNeuron.pause(job_id)
    assert_receive {:stopping, first}
    assert {:ok, "pause_pending"} = MirrorNeuron.pause(job_id)
    assert {:error, :pause_cleanup_pending} = MirrorNeuron.resume(job_id)

    assert {:ok, %{"status" => "paused", "pause_cleanup_status" => "pending"}} =
             RedisStore.fetch_job(job_id)

    [{coordinator, _}] = Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id})
    send(coordinator, {:agent_failed, "worker", :stopped})
    send(coordinator, {:agent_completed_run, "worker", %{}})
    assert {:ok, "pause_pending"} = MirrorNeuron.pause(job_id)

    send(first, {:stop_result, {:error, :injected}})

    wait_until(fn ->
      match?({:ok, %{"pause_cleanup_status" => "failed"}}, RedisStore.fetch_job(job_id))
    end)

    assert {:error, :retry_pause_cleanup} = MirrorNeuron.resume(job_id)

    assert {:ok, "pause_pending"} = MirrorNeuron.pause(job_id)
    assert_receive {:stopping, retry}
    send(retry, {:stop_result, :ok})

    wait_until(fn ->
      match?({:ok, %{"pause_cleanup_status" => "complete"}}, RedisStore.fetch_job(job_id))
    end)

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    refute_receive {:stopping, _}
  end
end
