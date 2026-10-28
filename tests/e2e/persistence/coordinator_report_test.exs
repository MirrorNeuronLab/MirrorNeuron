defmodule MirrorNeuron.Runtime.CoordinatorReportTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{Delivery, WorkflowMessage}

  setup do
    Application.ensure_all_started(:telemetry)

    unless Process.whereis(MirrorNeuron.Redis.Connection) do
      url = MirrorNeuron.Config.string("MN_REDIS_URL", :redis_url)
      start_supervised!({Redix, {url, [name: MirrorNeuron.Redis.Connection]}})
    end

    namespace = "coordinator_report_test_#{System.unique_integer([:positive])}"
    previous = System.get_env("MN_REDIS_NAMESPACE")
    System.put_env("MN_REDIS_NAMESPACE", namespace)

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_REDIS_NAMESPACE", previous),
        else: System.delete_env("MN_REDIS_NAMESPACE")
    end)

    :ok
  end

  test "a readmitted delivery reports its new attempt after the old report was acknowledged" do
    state = %{job_id: "run", node: %{node_id: "vision"}, runtime_context: %{lease_epoch: 1}}
    agent = Delivery.coordinator_agent_id()
    consumer = Delivery.consumer_id(state.job_id, agent)

    source =
      Message.new("run", "sampler", "vision", "frames", %{"batch_id" => "batch"},
        message_id: "same-source"
      )

    for attempt <- 1..2 do
      message =
        source
        |> put_in(["headers", "mn.workflow.attempt_id"], "detect:attempt:#{attempt}")
        |> put_in(["envelope", "attempt"], attempt)

      report_id =
        WorkflowMessage.coordinator_report_id(
          state,
          message,
          "workflow_message_received",
          "received"
        )

      body = %{
        "kind" => "workflow_message_received",
        "agent_id" => "vision",
        "message" => Delivery.stable_workflow_message(message)
      }

      assert :ok = Delivery.report(state.job_id, "vision", report_id, body, attempt_epoch: 1)
      assert {:ok, 1} = RedisStore.delivery_pending_count(state.job_id, agent)
      assert {:ok, [delivery]} = Delivery.read(state.job_id, agent, consumer)

      assert get_in(delivery.message, ["body", "message", "headers", "mn.workflow.attempt_id"]) ==
               "detect:attempt:#{attempt}"

      assert :ok = Delivery.ack(state.job_id, agent, consumer, delivery)

      replay = put_in(message, ["envelope", "attempt"], attempt + 5)
      replay_body = Map.put(body, "message", Delivery.stable_workflow_message(replay))

      assert :ok =
               Delivery.report(state.job_id, "vision", report_id, replay_body, attempt_epoch: 1)

      assert {:ok, 0} = RedisStore.delivery_pending_count(state.job_id, agent)

      conflicting = put_in(body, ["message", "body", "batch_id"], "changed-batch")

      assert {:error, {:message_id_conflict, ^report_id, "acked"}} =
               Delivery.report(state.job_id, "vision", report_id, conflicting, attempt_epoch: 1)
    end

    RedisStore.delete_job(state.job_id)
  end
end
