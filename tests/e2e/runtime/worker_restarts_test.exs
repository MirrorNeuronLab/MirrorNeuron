defmodule MirrorNeuron.Runtime.WorkerRestartsTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.RuntimeTest.CrashOnceCounter
  alias MirrorNeuron.RuntimeTest.CrashOnceRunner
  alias MirrorNeuron.RuntimeTest.CrashTwiceCounter
  alias MirrorNeuron.RuntimeTest.CrashTwiceRunner
  alias MirrorNeuron.RuntimeTest.LongSleepRunner

  test "restarts a missing agent and replays its inflight message" do
    {:ok, counter_pid} = start_supervised(CrashOnceCounter)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "agent_recovery_test",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "recover"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => CrashOnceRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "max_agent_restart_attempts" => 2
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(fn -> worker_pid(job_id) end, 2_000)
    wait_until(fn -> attempt_started?(job_id, 1) end, 2_000)

    assert {:ok, before_restart} = MirrorNeuron.inspect_job(job_id)

    [{pid, _}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

    Process.exit(pid, :kill)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 8_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "recovered"]) == true
    assert get_in(job, ["result", "output", "invocation"]) == 2
    assert job["attempt"] == before_restart["attempt"] + 1
    assert job["recovery_mode"] == "clean_restart"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_clean_restart_scheduled"))
    assert Enum.any?(events, &(&1["type"] == "job_attempt_started" && &1["attempt"] == 2))

    GenServer.stop(counter_pid)
    RedisStore.delete_job(job_id)
  end

  test "batch job fails after restart policy attempts are exhausted" do
    # This test deliberately kills two workers. Keep the health checker from
    # racing those explicit restart transitions under a loaded CI runner.
    previous_health_interval = Application.get_env(:mirror_neuron, :job_health_check_interval_ms)
    Application.put_env(:mirror_neuron, :job_health_check_interval_ms, 1_000)

    on_exit(fn ->
      restore_application_env(:job_health_check_interval_ms, previous_health_interval)
    end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "batch_restart_policy_exhaustion",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "fail after retry"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => LongSleepRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => 1,
          "interval_ms" => 60_000,
          "delay_ms" => 1,
          "delay_function" => "constant",
          "max_delay_ms" => 1,
          "mode" => "fail"
        },
        "reschedule" => %{"attempts" => 0}
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(fn -> worker_pid(job_id) end, 3_000)
    wait_until(fn -> attempt_started?(job_id, 1) end, 2_000)

    [{first_pid, _}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

    Process.exit(first_pid, :kill)
    trigger_missing_agent_health_check(job_id, "worker", first_pid)

    wait_until(
      fn ->
        with {:ok, restarted} <- MirrorNeuron.inspect_job(job_id) do
          restarted["attempt"] == 2 and
            replacement_worker_pid?(job_id, first_pid) and
            attempt_started?(job_id, 2)
        else
          _ -> false
        end
      end,
      12_000
    )

    [{second_pid, _}] =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

    Process.exit(second_pid, :kill)
    trigger_missing_agent_health_check(job_id, "worker", second_pid)

    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 12_000)
    assert job["status"] == "failed"
    assert get_in(job, ["restart_budget", "attempts"]) == 1

    wait_until(
      fn ->
        agent_unregistered?(job_id, "root") and agent_unregistered?(job_id, "worker") and
          job_runner_unregistered?(job_id)
      end,
      2_000
    )

    RedisStore.delete_job(job_id)
  end

  test "long-lived jobs do not fail when recovery attempts exceed the normal cap" do
    :ok = CrashTwiceCounter.init()

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "service_agent_recovery_test",
      "type" => "service",
      "entrypoints" => ["root"],
      "initial_inputs" => %{"root" => [%{"work" => "keep recovering"}]},
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "do_work"}
        },
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => CrashTwiceRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "root", "to_node" => "worker", "message_type" => "do_work"}
      ],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => 1,
          "interval_ms" => 100,
          "delay_ms" => 1,
          "delay_function" => "constant",
          "max_delay_ms" => 1,
          "mode" => "delay"
        }
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)

    for invocation <- 1..2 do
      wait_until(fn -> CrashTwiceCounter.invocations() == invocation end, 3_000)

      wait_until(
        fn ->
          match?(
            [{_pid, _}],
            Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})
          )
        end,
        2_000
      )

      [{pid, _}] =
        Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})

      Process.exit(pid, :kill)

      wait_until(
        fn ->
          with {:ok, attempt_job} <- MirrorNeuron.inspect_job(job_id) do
            attempt_job["status"] == "running" and
              attempt_job["attempt"] >= invocation + 1 and
              event_count(job_id, "job_attempt_started") >= invocation + 1
          else
            _ -> false
          end
        end,
        3_000
      )
    end

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.count(events, &(&1["type"] == "job_attempt_started")) >= 3

    # Workflow readiness may also recover an agent. Verify the required
    # clean attempts themselves rather than forbidding unrelated readiness.
    for attempt <- 1..3 do
      assert Enum.any?(events, fn event ->
               event["type"] == "job_attempt_started" and event["attempt"] == attempt and
                 event["mode"] == "clean_restart"
             end)
    end

    wait_until(
      fn ->
        {:ok, events} = MirrorNeuron.events(job_id)
        Enum.any?(events, &(&1["type"] == "service_agent_completed"))
      end,
      12_000
    )

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert job["job_type"] == "service"
    assert job["attempt"] >= 3

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end
end
