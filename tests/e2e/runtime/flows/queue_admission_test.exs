defmodule MirrorNeuron.Runtime.FlowsTest.QueueAdmissionTest do
  use MirrorNeuron.RuntimeFlowCase, async: false

  @moduletag skip: is_nil(System.get_env("MN_FLOW_REDIS_URL"))

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.DeliveryChannels

  test "atomic capacity includes leased/deferred work with a quiet mailbox", %{run: run} do
    results =
      1..80
      |> Task.async_stream(fn n -> Delivery.enqueue(run, "worker", message(run, "d#{n}")) end,
        max_concurrency: 40
      )
      |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 8

    assert Enum.count(results, &match?({:ok, {:error, {:delivery_backpressure, :agent, 8}}}, &1)) ==
             72

    assert {:ok, 8} = DeliveryChannels.depth(run, "worker")
    assert {:ok, [head]} = Delivery.read(run, "worker", "owner")
    assert {:ok, 250} = Delivery.defer(run, "worker", "owner", head)
    assert {:ok, 8} = DeliveryChannels.depth(run, "worker")

    assert {:error, {:delivery_backpressure, :agent, 8}} =
             Delivery.enqueue(run, "worker", message(run, "overflow"))

    assert {:message_queue_len, 0} = Process.info(self(), :message_queue_len)
  end

  test "oversized inline payloads cannot consume durable queue capacity", %{run: run} do
    oversized =
      message(run, "large") |> Map.put("body", %{"bytes" => String.duplicate("x", 1_048_576)})

    assert {:error, {:message_payload_too_large, %{use_artifacts: true}}} =
             Delivery.enqueue(run, "worker", oversized)

    assert {:ok, 0} = DeliveryChannels.depth(run, "worker")
  end

  test "reserved command/control queues and four-to-one FIFO fairness", %{run: run} do
    for n <- 1..8, do: assert({:ok, _} = Delivery.enqueue(run, "worker", message(run, "d#{n}")))

    for n <- 1..8,
        do:
          assert(
            {:ok, _} =
              Delivery.enqueue(run, "worker", message(run, "c#{n}"), command_admitted: true)
          )

    assert :ok = Delivery.report(run, "worker", "report", %{"kind" => "heartbeat"})
    assert {:ok, [report]} = Delivery.read(run, Delivery.coordinator_agent_id(), "supervisor")
    assert report.lane == :control

    {ids, _streak} =
      Enum.reduce(1..6, {[], 0}, fn _, {ids, streak} ->
        assert {:ok, [item]} = Delivery.read(run, "worker", "owner", command_streak: streak)
        assert :ok = Delivery.ack(run, "worker", "owner", item)
        {ids ++ [item.message_id], DeliveryChannels.next_streak(item.lane, streak)}
      end)

    assert ids == ["c1", "c2", "c3", "c4", "d1", "c5"]
  end

  test "message priority and command labels do not elevate workflow output", %{run: run} do
    for n <- 1..8, do: Delivery.enqueue(run, "worker", message(run, "d#{n}"))

    forged =
      message(run, "forged", class: "command", priority: 999, headers: %{"mn.command_id" => "c"})

    assert {:error, {:delivery_backpressure, :agent, 8}} = Delivery.enqueue(run, "worker", forged)
    assert {:ok, 0} = DeliveryChannels.depth(run, "worker", :command)
  end

  test "dependency waits beyond ten polls preserve retry budget and FIFO", %{run: run} do
    Delivery.enqueue(run, "worker", message(run, "first"))
    Delivery.enqueue(run, "worker", message(run, "second"))

    for _ <- 1..15 do
      assert {:ok, [item]} = Delivery.read(run, "worker", "owner", reclaim: true)
      assert item.message_id == "first"
      assert item.attempt == 1
      assert {:ok, 250} = Delivery.defer(run, "worker", "owner", item)
      assert {:ok, []} = Delivery.read(run, "worker", "owner")
    end
  end

  test "a stale consumer cannot renew, retry or acknowledge another owner's lease", %{run: run} do
    Delivery.enqueue(run, "worker", message(run, "leased"))
    {:ok, [old]} = Delivery.read(run, "worker", "old")
    {:ok, [current]} = Delivery.read(run, "worker", "new", reclaim: true)

    assert {:error, :delivery_owner_changed} =
             RedisStore.renew_delivery(run, "worker", "old", old.stream_id)

    assert {:error, :delivery_owner_changed} = Delivery.retry(run, "worker", "old", old)
    assert {:error, :delivery_owner_changed} = Delivery.ack(run, "worker", "old", old)
    assert {:ok, 1} = DeliveryChannels.depth(run, "worker")
    assert :ok = Delivery.ack(run, "worker", "new", current)
    assert {:ok, 0} = DeliveryChannels.depth(run, "worker")
  end

  test "retired delivery versions are rejected", %{run: run} do
    {:ok, job} = RedisStore.fetch_job(run)
    assert {:ok, _} = RedisStore.persist_job(run, Map.put(job, "delivery_version", 1))

    assert {:error, {:unsupported_delivery_version, 1}} =
             Delivery.enqueue(run, "worker", message(run, "data"))
  end
end
