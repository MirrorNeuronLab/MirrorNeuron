defmodule MirrorNeuron.Runtime.FlowsTest.CommandReceiptsTest do
  use MirrorNeuron.RuntimeFlowCase, async: false

  @moduletag skip: is_nil(System.get_env("MN_FLOW_REDIS_URL"))

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Persistence.SignalStore
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.Signals
  alias MirrorNeuron.Runtime.CommandReceipts

  test "only the declared completion owner can finish a correlated receipt", %{run: run} do
    assert {:ok, _} =
             CommandReceipts.prepare(run, "cmd", "input", %{}, %{"completion_agent" => "worker"})

    assert {:ok, _} = CommandReceipts.update(run, "cmd", "accepted")

    assert :not_boundary =
             CommandReceipts.update(run, "cmd", "completed", "router", %{"applied" => true})

    assert {:ok, _} = CommandReceipts.update(run, "cmd", "executing", "worker")
    assert {:ok, _} = CommandReceipts.update(run, "cmd", "not_accepted")
    assert {:ok, %{"status" => "executing", "accepted" => true}} = CommandReceipts.get(run, "cmd")
    assert {:ok, _} = CommandReceipts.update(run, "cmd", "completed", "worker", %{"value" => 42})

    assert {:ok, %{"status" => "completed", "result" => %{"value" => 42}, "revision" => 3}} =
             CommandReceipts.get(run, "cmd")

    assert {:ok, _} = CommandReceipts.update(run, "cmd", "completed", "worker", %{"value" => 99})
    assert {:ok, [event]} = SignalStore.read(run, "responses", 0)
    assert event["payload"]["result"] == %{"value" => 42}
    assert event["sequence"] == 3

    {:ok, _} =
      Signals.publish(
        run,
        "responses",
        %{
          "type" => "runtime.command_accepted",
          "payload" => %{"command_id" => "cmd", "status" => "accepted", "revision" => 1}
        },
        "cmd"
      )

    assert {:ok, [latest]} = SignalStore.read(run, "responses", 0)
    assert latest["payload"]["status"] == "completed"

    assert {:error, :request_conflict} =
             CommandReceipts.prepare(run, "cmd", "input", %{"changed" => true}, %{})
  end

  test "queue admission atomically records acceptance and retry preserves protected history", %{
    run: run
  } do
    {:ok, _} =
      CommandReceipts.prepare(run, "atomic", "input", %{}, %{
        "entrypoint" => "worker",
        "completion_agent" => "worker"
      })

    cmd = message(run, "atomic", headers: %{"mn.command_id" => "atomic"})
    assert {:ok, _} = Delivery.enqueue(run, "worker", cmd, command_admitted: true)
    # Simulate a crash before SendRunInput publishes its acceptance response.
    assert {:ok, %{"accepted" => true, "revision" => 1}} = CommandReceipts.get(run, "atomic")
    {:ok, _} = Signals.error(run, "worker", "atomic", :runner_failed)
    assert :ok = RedisStore.clear_job_attempt_state(run)
    assert {:ok, %{"accepted" => true}} = CommandReceipts.get(run, "atomic")
    assert {:ok, [_incident]} = SignalStore.read(run, "errors", 0)
  end

  test "terminal cancellation settles accepted receipts without inventing completion", %{run: run} do
    {:ok, _} =
      CommandReceipts.prepare(run, "pending", "input", %{}, %{"completion_agent" => "worker"})

    assert {:ok, %{"accepted" => nil}} = CommandReceipts.get(run, "pending")
    {:ok, _} = CommandReceipts.update(run, "pending", "accepted")
    {:ok, _} = Signals.subscribe(run, "responses")
    {:ok, job} = RedisStore.fetch_job(run)

    RedisStore.storage_command([
      "SET",
      RedisStore.storage_key(["job", run]),
      Jason.encode!(Map.put(job, "status", "cancelled"))
    ])

    assert {:ok, _pid} = CommandReceipts.settle_run_async(run)
    assert_receive {:runtime_signal_available, "responses"}, 250
    assert {:ok, receipt} = CommandReceipts.get(run, "pending")
    assert receipt["status"] == "cancelled"
    assert receipt["accepted"] == true
    refute Map.has_key?(receipt, "result")
    assert :ok = Delivery.expire_job(run)

    {:ok, ttl} =
      RedisStore.storage_command([
        "TTL",
        RedisStore.storage_key(["job", run, "signals", "responses", "incidents"])
      ])

    assert ttl > 3600
  end
end
