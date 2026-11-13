defmodule MirrorNeuron.Runtime.DurableReportsTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.AgentWorker
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.DeliveryChannels
  alias MirrorNeuron.RuntimeTest.ExplicitCheckpointAgent

  test "keeps a terminal report durable while the coordinator is gone" do
    job_id = "worker_fallback_test-#{System.unique_integer([:positive])}"
    persist_delivery_job(job_id)

    node = %{
      node_id: "sink",
      agent_type: "aggregator",
      role: "sink",
      config: %{"complete_on_message" => true, "terminal_sink" => true, "complete_run" => true}
    }

    coordinator =
      spawn(fn ->
        receive do
        after
          1 -> :ok
        end
      end)

    Process.exit(coordinator, :kill)

    runtime_context = %{
      delivery_version: 2,
      lease_epoch: 1,
      graph_id: "worker_fallback_test",
      job_name: "worker_fallback_test",
      entrypoints: ["sink"],
      placement_policy: "local",
      recovery_policy: "local_restart",
      submitted_at:
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      manifest_version: "1.0"
    }

    assert {:ok, pid} =
             AgentWorker.start_link({job_id, node, [], [], coordinator, runtime_context})

    message =
      Message.new(job_id, "external", "sink", "manual_result", %{"value" => "done"},
        correlation_id: "test-correlation"
      )

    GenServer.cast(pid, {:deliver, message})

    wait_until(fn ->
      DeliveryChannels.depth(job_id, Delivery.coordinator_agent_id(), :control) == {:ok, 1}
    end)

    assert {:ok, %{"status" => "running"} = retained} = RedisStore.fetch_job(job_id)
    refute retained["result"]

    consumer = Delivery.consumer_id(job_id, Delivery.coordinator_agent_id())

    assert {:ok, [delivery]} =
             Delivery.read(job_id, Delivery.coordinator_agent_id(), consumer)

    report = Message.body(delivery.message)
    assert report["kind"] == "agent_completed_run"
    assert report["agent_id"] == "sink"
    assert get_in(report, ["result", "count"]) == 1
    assert get_in(report, ["result", "last_message", "value"]) == "done"

    assert :ok =
             Delivery.ack(
               job_id,
               Delivery.coordinator_agent_id(),
               consumer,
               delivery
             )

    GenServer.stop(pid)
    RedisStore.delete_job(job_id)
  end

  test "workflow coordinator reports remain idempotent across delivery retries" do
    job_id = "workflow_report_retry_test-#{System.unique_integer([:positive])}"
    persist_delivery_job(job_id)
    report_id = "stable-workflow-received-report"

    first_attempt =
      Message.new(job_id, "external", "retrying_worker", "retryable_work", %{"value" => 1},
        correlation_id: "retry-correlation",
        headers: %{
          "mn.workflow.run_id" => "workflow-run",
          "mn.workflow.step_id" => "retry_step",
          "mn.workflow.attempt" => 1,
          "mn.workflow.attempt_id" => "retry_step:attempt:1",
          "mn.workflow.idempotency_key" => "workflow-run:retry_step:1"
        }
      )
      |> put_in(["envelope", "attempt"], 1)

    second_attempt = put_in(first_attempt, ["envelope", "attempt"], 2)

    report_body = fn message ->
      %{
        "kind" => "workflow_message_received",
        "agent_id" => "retrying_worker",
        "message" => Delivery.stable_workflow_message(message)
      }
    end

    assert :ok =
             Delivery.report(
               job_id,
               "retrying_worker",
               report_id,
               report_body.(first_attempt)
             )

    assert :ok =
             Delivery.report(
               job_id,
               "retrying_worker",
               report_id,
               report_body.(second_attempt)
             )

    assert DeliveryChannels.depth(job_id, Delivery.coordinator_agent_id(), :control) ==
             {:ok, 1}

    consumer = Delivery.consumer_id(job_id, Delivery.coordinator_agent_id())

    assert {:ok, [report]} =
             Delivery.read(job_id, Delivery.coordinator_agent_id(), consumer)

    body = Message.body(report.message)
    assert body["kind"] == "workflow_message_received"
    refute Map.has_key?(get_in(body, ["message", "envelope"]), "attempt")

    assert :ok =
             Delivery.ack(
               job_id,
               Delivery.coordinator_agent_id(),
               consumer,
               report
             )

    RedisStore.delete_job(job_id)
  end

  test "heartbeats and checkpoint actions never serialize agent memory" do
    job_id = "checkpoint_perf_test-#{System.unique_integer([:positive])}"
    persist_delivery_job(job_id)
    parent = self()

    coordinator =
      spawn(fn ->
        checkpoint_proxy(parent, job_id)
      end)

    node = %{
      node_id: "checkpoint_agent",
      agent_type: "module",
      role: "root",
      config: %{"module" => ExplicitCheckpointAgent}
    }

    runtime_context = %{
      delivery_version: 2,
      lease_epoch: 1,
      graph_id: "checkpoint_perf_test",
      job_name: "checkpoint_perf_test",
      entrypoints: ["checkpoint_agent"],
      placement_policy: "local",
      recovery_policy: "local_restart",
      submitted_at:
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      manifest_version: "1.0"
    }

    assert {:ok, pid} =
             AgentWorker.start_link({job_id, node, [], [], coordinator, runtime_context})

    assert {:ok, observation} = RedisStore.fetch_agent(job_id, "checkpoint_agent")
    assert observation["agent_id"] == "checkpoint_agent"
    refute Map.has_key?(observation, "current_state")
    refute Map.has_key?(observation, "inflight_message")
    refute Map.has_key?(observation, "pending_messages")
    refute Map.has_key?(observation["metadata"], "recovery_state")

    refute_receive {:checkpoint_persisted, _snapshot}, 200

    message =
      Message.new(job_id, "external", "checkpoint_agent", "checkpoint", %{"value" => "save"},
        correlation_id: "checkpoint-correlation"
      )

    GenServer.cast(pid, {:deliver, message})

    assert_receive {:checkpoint_ignored, %{"metadata" => %{"explicit_checkpoint" => true}}},
                   1_000

    assert {:ok, observation} = RedisStore.fetch_agent(job_id, "checkpoint_agent")
    refute Map.has_key?(observation["metadata"], "explicit_checkpoint")
    refute Map.has_key?(observation["metadata"], "recovery_state")

    refute_receive {:checkpoint_ignored, _snapshot}, 200

    GenServer.stop(pid)
    Process.exit(coordinator, :kill)
    RedisStore.delete_job(job_id)
  end
end
