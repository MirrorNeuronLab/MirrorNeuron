defmodule MirrorNeuron.RuntimeReliabilityTest.CallsTest do
  use MirrorNeuron.RuntimeControlCase, async: false

  import ExUnit.CaptureLog

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.RuntimeControlCase.SlowJob
  alias MirrorNeuron.RuntimeControlCase.CrashOnceJob

  test "runtime control and durable delivery timing defaults are conservative" do
    assert Runtime.job_call_timeout_ms() == 15_000
    assert Runtime.cancel_job_call_timeout_ms() == 5_000
    assert Delivery.lease_ms() == 30_000
    assert Delivery.max_attempts() == 10
  end

  test "independent clean-attempt bursts do not exhaust the shared job supervisor" do
    table = :ets.new(:job_supervisor_restart_burst, [:public])
    supervisor_pid = Process.whereis(MirrorNeuron.Runtime.JobSupervisor)

    for id <- 1..4 do
      assert {:ok, _pid} =
               Horde.DynamicSupervisor.start_child(
                 MirrorNeuron.Runtime.JobSupervisor,
                 {CrashOnceJob, {id, table, self()}}
               )

      assert_receive {:crash_once_job_started, ^id, 1}, 1_000
      assert_receive {:crash_once_job_started, ^id, 2}, 1_000
    end

    assert Process.whereis(MirrorNeuron.Runtime.JobSupervisor) == supervisor_pid
  end

  test "state-bearing coordinator events are delivered durably before completion" do
    assert Delivery.coordinator_event_requires_ack?("workflow_step_branch")
    assert Delivery.coordinator_event_requires_ack?(:workflow_step_scatter)
    assert Delivery.coordinator_event_requires_ack?("workflow_step_skipped")
    assert Delivery.coordinator_event_requires_ack?("sandbox_job_completed")
  end

  test "runtime control and durable delivery timing honor env overrides" do
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "2500")
    System.put_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS", "1500")
    System.put_env("MN_MESSAGE_ACK_TIMEOUT_MS", "2500")
    System.put_env("MN_MESSAGE_DELIVERY_MAX_ATTEMPTS", "3")

    assert Runtime.job_call_timeout_ms() == 2_500
    assert Runtime.cancel_job_call_timeout_ms() == 1_500
    assert Delivery.lease_ms() == 2_500
    assert Delivery.max_attempts() == 3

    Application.put_env(:mirror_neuron, :job_call_timeout_ms, 4_000)
    Application.put_env(:mirror_neuron, :cancel_job_call_timeout_ms, 2_000)
    Application.put_env(:mirror_neuron, :message_ack_timeout_ms, 4_500)
    Application.put_env(:mirror_neuron, :message_delivery_max_attempts, 7)
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "0")
    System.put_env("MN_CANCEL_JOB_CALL_TIMEOUT_MS", "0")
    System.delete_env("MN_MESSAGE_ACK_TIMEOUT_MS")
    System.delete_env("MN_MESSAGE_DELIVERY_MAX_ATTEMPTS")

    assert Runtime.job_call_timeout_ms() == 4_000
    assert Runtime.cancel_job_call_timeout_ms() == 2_000
    assert Delivery.lease_ms() == 4_500
    assert Delivery.max_attempts() == 7
  end

  test "missing runtime job returns a structured not-running error" do
    job_id = unique_id("missing-job")

    assert {:error, {:job_not_running, ^job_id}} = Runtime.pause_job(job_id)
    assert Runtime.error_message({:job_not_running, job_id}) =~ "not running"
  end

  test "job control call timeout stays local to the caller" do
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "10")
    job_id = unique_id("slow-job")
    pid = start_supervised!({SlowJob, job_id})

    capture_log(fn ->
      assert {:error, {:job_call_timeout, ^job_id, 10}} = Runtime.pause_job(job_id)
    end)

    Process.exit(pid, :kill)
  end

  test "cancellation reconciliation terminates a local runner without calling cancel" do
    job_id = unique_id("local-job-stop")

    assert {:ok, pid} =
             Horde.DynamicSupervisor.start_child(
               MirrorNeuron.Runtime.JobSupervisor,
               {SlowJob, job_id}
             )

    monitor = Process.monitor(pid)
    started_at = System.monotonic_time(:millisecond)

    assert :ok = Runtime.terminate_local_job(job_id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  test "delivery is durably accepted even while the target agent is unavailable" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        job_id = unique_id("delivery-job")
        agent_id = "missing-agent"
        message_id = unique_id("message")

        assert {:ok, _} =
                 RedisStore.persist_job(
                   job_id,
                   Map.put(active_job(job_id), "delivery_version", 2)
                 )

        message =
          MirrorNeuron.Message.new(job_id, "source", agent_id, "hello", %{},
            message_id: message_id
          )

        assert :ok = Runtime.deliver(job_id, agent_id, message)

        assert {:ok, receipt} =
                 RedisStore.fetch_delivery_receipt(job_id, agent_id, message_id)

        assert receipt["status"] == "queued"
        assert receipt["attempts"] == 0
      end)
    end
  end
end
