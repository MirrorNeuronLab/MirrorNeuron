defmodule MirrorNeuron.Runtime.FlowsTest.SignalsTest do
  use MirrorNeuron.RuntimeFlowCase, async: false

  @moduletag skip: is_nil(System.get_env("MN_FLOW_REDIS_URL"))

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Persistence.SignalStore
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.Signals

  test "first failure wakes an observer immediately and recovery retains incident identity", %{
    run: run
  } do
    {:ok, flag} = Signals.subscribe(run, "errors")
    assert {:ok, first} = Signals.error(run, "worker", "request", :runner_failed)
    assert_receive {:runtime_signal_available, "errors"}, 250
    for _ <- 1..50, do: Signals.error(run, "worker", "request", :runner_failed)
    refute_receive {:runtime_signal_available, "errors"}, 10
    assert {:ok, recovered} = Signals.error(run, "worker", "request", :runner_failed, :recovered)
    assert first["payload"]["incident_id"] == recovered["payload"]["incident_id"]
    assert recovered["payload"]["count"] == 51
    assert recovered["payload"]["first_occurrence"]["event_id"] == first["event_id"]
    Signals.rearm(flag)
    assert {:ok, [event]} = SignalStore.read(run, "errors", first["sequence"])
    assert event["payload"]["state"] == "recovered"
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(run)
  end

  test "runner failure is observable before retry backoff completes", %{run: run} do
    {state, context} =
      executor(run, %{"fail_first" => true, "max_attempts" => 2, "retry_backoff_ms" => 500})

    {:ok, _} = Signals.subscribe(run, "errors")

    task =
      Task.async(fn ->
        MirrorNeuron.Builtins.Executor.handle_message(message(run, "retry"), state, context)
      end)

    assert_receive {:runner_attempt, 1}
    assert_receive {:runtime_signal_available, "errors"}, 250
    assert {:ok, [first]} = SignalStore.read(run, "errors", 0)
    assert first["payload"]["state"] in ["observed", "retrying"]
    refute_receive {:runner_attempt, 2}, 100
    assert {:ok, _, _} = Task.await(task)
    assert {:ok, [last]} = SignalStore.read(run, "errors", 0)
    assert last["payload"]["incident_id"] == first["payload"]["incident_id"]
    assert last["payload"]["state"] == "recovered"
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(run)
  end

  test "the owning workflow boundary resolves a fallback incident without changing run lifecycle",
       %{run: run} do
    {:ok, first} =
      Signals.error(run, "failed-worker", "original-input", :runner_failed, :observed,
        step_id: "work"
      )

    Signals.workflow(run, %{
      type: :workflow_step_completed,
      agent_id: "fallback-boundary",
      payload: %{"step_id" => "work"}
    })

    assert {:ok, [resolved]} = SignalStore.read(run, "errors", 0)
    assert resolved["payload"]["incident_id"] == first["payload"]["incident_id"]
    assert resolved["payload"]["state"] == "recovered"
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(run)
  end

  test "missing replay history and future cursors fail explicitly", %{run: run} do
    Signals.error(run, "worker", "one", :first_failure)
    Signals.error(run, "worker", "two", :second_failure)
    Signals.error(run, "worker", "three", :third_failure)

    RedisStore.storage_command([
      "LTRIM",
      RedisStore.storage_key(["job", run, "signals", "errors", "events"]),
      "-1",
      "-1"
    ])

    assert {:error, :signal_replay_gap} = SignalStore.read(run, "errors", 1)
    assert {:error, :signal_replay_gap} = SignalStore.read(run, "errors", 99)
    assert {:ok, incidents} = SignalStore.read(run, "errors", 0)
    assert length(incidents) == 3
  end

  test "unconfirmed replication remains unavailable even when the primary has the event", %{
    run: run
  } do
    old_replicas = System.get_env("MN_REDIS_WAIT_REPLICAS")
    old_timeout = System.get_env("MN_REDIS_WAIT_TIMEOUT_MS")

    on_exit(fn ->
      for {key, value} <- [
            {"MN_REDIS_WAIT_REPLICAS", old_replicas},
            {"MN_REDIS_WAIT_TIMEOUT_MS", old_timeout}
          ] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    {:ok, _} = Signals.subscribe(run, "errors")
    System.put_env("MN_REDIS_WAIT_REPLICAS", "1")
    System.put_env("MN_REDIS_WAIT_TIMEOUT_MS", "10")

    assert {:error, {:signal_replication_unconfirmed, _}} =
             Signals.error(run, "worker", "unconfirmed", :runner_failed)

    assert_receive {:runtime_signal_unavailable, "errors"}, 250
    assert {:error, {:signal_replication_unconfirmed, _}} = SignalStore.read(run, "errors", 0)
  end

  @tag timeout: 30_000
  test "protected observer latency remains bounded under saturated data traffic", %{run: run} do
    for n <- 1..8, do: Delivery.enqueue(run, "worker", message(run, "full#{n}"))
    parent = self()

    observer =
      Task.async(fn ->
        {:ok, flag} = Signals.subscribe(run, "errors")
        send(parent, :observer_ready)

        Enum.reduce_while(1..500, {0, []}, fn _, {cursor, samples} ->
          Signals.rearm(flag)
          {:ok, events} = SignalStore.read(run, "errors", cursor)
          now = System.monotonic_time(:microsecond)

          samples =
            samples ++
              Enum.map(events, fn event ->
                (now - String.to_integer(event["payload"]["correlation_id"])) / 1000
              end)

          cursor = if events == [], do: cursor, else: List.last(events)["sequence"]

          if length(samples) >= 200 do
            {:halt, samples}
          else
            receive do
              {:runtime_signal_available, "errors"} -> :ok
            after
              1000 -> flunk("observer was not notified")
            end

            {:cont, {cursor, samples}}
          end
        end)
      end)

    assert_receive :observer_ready

    writers =
      for writer <- 1..8,
          do:
            Task.async(fn ->
              for n <- 1..250,
                  do: Delivery.enqueue(run, "worker", message(run, "overflow#{writer}-#{n}"))
            end)

    for _ <- 1..200 do
      detected = System.monotonic_time(:microsecond)
      assert {:ok, _} = Signals.error(run, "worker", to_string(detected), :runner_failed)
    end

    samples = Task.await(observer, 10_000) |> Enum.sort()
    Enum.each(writers, &Task.await(&1, 10_000))
    p95 = Enum.at(samples, 189)
    p99 = Enum.at(samples, 197)

    IO.puts(
      "protected Redis observer latency: p95=#{Float.round(p95, 2)}ms p99=#{Float.round(p99, 2)}ms"
    )

    assert p95 <= 250
    assert p99 <= 1000
  end
end
