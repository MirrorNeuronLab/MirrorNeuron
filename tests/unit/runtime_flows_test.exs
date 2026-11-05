defmodule MirrorNeuron.Runtime.FlowsTest.Handler do
  use MirrorNeuron.AgentTemplate
  def init(_node), do: {:ok, %{handled: 0}}

  def handle_message(message, state, context) do
    id = MirrorNeuron.Message.id(message)
    send(context.coordinator, {:handler_started, id, self()})

    if id == "blocking",
      do:
        (receive do
           :release_handler -> :ok
         end)

    {:ok, %{handled: state.handled + 1}, []}
  end
end

defmodule MirrorNeuron.Runtime.FlowsTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.{RedisStore, DeliveryStore, SignalStore}

  alias MirrorNeuron.Runtime.{
    Delivery,
    DeliveryChannels,
    Signals,
    CommandReceipts,
    InvocationOutbox
  }

  @moduletag skip: is_nil(System.get_env("MN_FLOW_REDIS_URL"))

  defmodule RetryRunner do
    def run(_payload, config, opts) do
      attempt = Keyword.fetch!(opts, :attempt)
      send(config["observer"], {:runner_attempt, attempt})

      if attempt == 1 and config["fail_first"] do
        {:error, %{"error" => "runner unavailable"}}
      else
        {:ok, %{"exit_code" => 0, "stdout" => "{}", "stderr" => "", "logs" => ""}}
      end
    end
  end

  setup_all do
    env_keys = [
      "MN_REDIS_URL",
      "MN_REDIS_HA_MODE",
      "MN_REDIS_NAMESPACE",
      "MN_REDIS_WAIT_REPLICAS",
      "MN_REDIS_RECONNECT_ATTEMPTS"
    ]

    previous_env = Map.new(env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    url = System.fetch_env!("MN_FLOW_REDIS_URL")
    System.put_env("MN_REDIS_URL", url)
    System.put_env("MN_REDIS_HA_MODE", "standalone")
    System.put_env("MN_REDIS_NAMESPACE", "flow-test-#{System.unique_integer([:positive])}")
    System.put_env("MN_REDIS_WAIT_REPLICAS", "0")
    System.put_env("MN_REDIS_RECONNECT_ATTEMPTS", "0")
    Application.ensure_all_started(:redix)
    Application.ensure_all_started(:horde)

    start_supervised!(
      {Horde.Registry, name: MirrorNeuron.DistributedRegistry, keys: :unique, members: :auto}
    )

    start_supervised!({Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry})
    start_supervised!({Registry, keys: :unique, name: MirrorNeuron.Runtime.ErrorMonitor.Registry})
    start_supervised!(MirrorNeuron.Runtime.ErrorMonitor)

    start_supervised!(
      {Task.Supervisor, name: MirrorNeuron.Runtime.SignalTaskSupervisor, max_children: 256}
    )

    unless Process.whereis(MirrorNeuron.Runtime.JobResponseRegistry),
      do:
        start_supervised!(
          {Registry, keys: :unique, name: MirrorNeuron.Runtime.JobResponseRegistry}
        )

    unless Process.whereis(MirrorNeuron.Runtime.JobResponseSupervisor),
      do:
        start_supervised!(
          {DynamicSupervisor,
           strategy: :one_for_one, name: MirrorNeuron.Runtime.JobResponseSupervisor}
        )

    start_supervised!({Redix, {url, [name: MirrorNeuron.Redis.Connection]}})
    start_supervised!(MirrorNeuron.Persistence.ProtectedRedis)
    start_supervised!({Registry, keys: :duplicate, name: MirrorNeuron.Runtime.SignalRegistry})
    :ok
  end

  setup do
    run = "run-#{System.unique_integer([:positive])}"

    job = %{
      "job_id" => run,
      "delivery_version" => 2,
      "status" => "running",
      "manifest" => %{
        "nodes" => [%{"node_id" => "worker", "config" => %{"max_queue_depth" => 8}}]
      }
    }

    {:ok, "OK"} =
      RedisStore.storage_command([
        "SET",
        RedisStore.storage_key(["job", run]),
        Jason.encode!(job)
      ])

    %{run: run}
  end

  defp message(run, id, opts \\ []),
    do:
      Message.new(
        run,
        "source",
        "worker",
        "work",
        %{"value" => id},
        Keyword.put(opts, :message_id, id)
      )

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

  test "outbox survives restart without repeating effects or rolling back newer command state", %{
    run: run
  } do
    first = message(run, "effect")
    Delivery.enqueue(run, "worker", first)
    {:ok, [delivery]} = Delivery.read(run, "worker", "owner")

    state = %{
      job_id: run,
      node: %{node_id: "worker"},
      runtime_context: %{delivery_version: 2},
      delivery_bucket: "worker",
      delivery_consumer: "owner",
      local_state: %{value: 0},
      processed_messages: 0
    }

    assert {:checkpointed, %{value: 1}, [{:noop}], 1, _} =
             InvocationOutbox.run(first, state, fn ->
               send(self(), :effect_ran)
               {:ok, %{value: 1}, [{:noop}]}
             end)

    assert_receive :effect_ran
    Delivery.defer(run, "worker", "owner", delivery)
    assert {:ok, recovered} = InvocationOutbox.recover(state)
    assert recovered.local_state == %{value: 1}

    assert {:checkpointed, %{value: 9}, [{:noop}], 2, _} =
             InvocationOutbox.run(
               first,
               %{recovered | local_state: %{value: 9}, processed_messages: 2},
               fn -> flunk("effect repeated") end
             )
  end

  test "an uncertain invocation cannot authorize a second effect", %{run: run} do
    msg = message(run, "uncertain")
    Delivery.enqueue(run, "worker", msg)
    Delivery.read(run, "worker", "owner")
    assert {:ok, "started"} = DeliveryStore.begin_invocation(run, "worker", "uncertain", "owner")

    state = %{
      job_id: run,
      node: %{node_id: "worker"},
      runtime_context: %{delivery_version: 2},
      delivery_bucket: "worker",
      delivery_consumer: "owner",
      local_state: %{},
      processed_messages: 0
    }

    assert {:error, :invocation_outcome_unconfirmed, %{}} =
             InvocationOutbox.run(msg, state, fn -> flunk("replayed uncertain effect") end)
  end

  test "a stopped service grant can be consumed only once by the delivery owner", %{run: run} do
    Delivery.enqueue(run, "worker", message(run, "service"))
    Delivery.read(run, "worker", "owner")

    begin = fn consumer, token ->
      DeliveryStore.begin_invocation(run, "worker", "service", consumer, token)
    end

    assert {:ok, "started"} = begin.("owner", nil)
    assert {:ok, "executing"} = begin.("owner", nil)
    assert {:ok, "owner_changed"} = begin.("another-consumer", "first")
    assert {:ok, "started"} = begin.("owner", "first")
    assert {:ok, "executing"} = begin.("owner", "first")
    assert {:ok, "started"} = begin.("owner", "second")
    assert {:ok, "executing"} = begin.("owner", "first")
    assert {:ok, "executing"} = begin.("owner", nil)
  end

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

  defp executor(run, config) do
    manager =
      start_supervised!(
        {MirrorNeuron.Execution.LeaseManager,
         name: __MODULE__.Leases, capacities: %{"default" => 1}}
      )

    node = %{
      node_id: "worker",
      config:
        Map.merge(
          config,
          %{"runner_module" => RetryRunner, "lease_manager" => manager, "observer" => self()}
        )
    }

    {:ok, state} = MirrorNeuron.Builtins.Executor.init(node)

    context = %{
      job_id: run,
      node: node,
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp"
    }

    {state, context}
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

  test "delayed runner output artifacts do not rerun the completed invocation", %{run: run} do
    previous = System.get_env("MN_ARTIFACT_RESOLVE_TIMEOUT_MS")
    System.put_env("MN_ARTIFACT_RESOLVE_TIMEOUT_MS", "0")
    directory = Path.join(System.tmp_dir!(), "mn-flow-artifact-#{run}")
    File.mkdir_p!(directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_ARTIFACT_RESOLVE_TIMEOUT_MS", previous),
        else: System.delete_env("MN_ARTIFACT_RESOLVE_TIMEOUT_MS")

      File.rm_rf!(directory)
    end)

    pointer = Path.join(directory, "result.json")

    {state, context} =
      executor(run, %{
        "max_attempts" => 1,
        "environment" => %{
          "MN_STEP_RESULT_FILE" => pointer,
          "MN_JOB_SHARED_STORAGE_ROOT" => directory
        }
      })

    task =
      Task.async(fn ->
        MirrorNeuron.Builtins.Executor.handle_message(message(run, "artifact"), state, context)
      end)

    assert_receive {:runner_attempt, 1}
    assert_receive {:agent_event, "worker", :executor_artifact_waiting, _}, 1000
    refute_receive {:runner_attempt, _}, 2750
    assert {:ok, []} = SignalStore.read(run, "errors", 0)

    {:ok, ref} =
      MirrorNeuron.Artifacts.StagedArtifact.stage(
        %{"outputs" => %{}, "artifacts" => [], "metrics" => %{}, "status" => "completed"},
        submission_path: directory,
        run_id: run
      )

    File.write!(pointer, Jason.encode!(%{"result_ref" => ref}))
    assert {:ok, _, _} = Task.await(task)
    refute_receive {:runner_attempt, _}, 10
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

  test "retired delivery versions are rejected", %{run: run} do
    {:ok, job} = RedisStore.fetch_job(run)
    assert {:ok, _} = RedisStore.persist_job(run, Map.put(job, "delivery_version", 1))

    assert {:error, {:unsupported_delivery_version, 1}} =
             Delivery.enqueue(run, "worker", message(run, "data"))
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

  test "commands apply at handler boundaries and worker crashes notify independently", %{run: run} do
    node = %{
      node_id: "worker",
      agent_type: "module",
      type: "generic",
      role: "worker",
      config: %{"module" => MirrorNeuron.Runtime.FlowsTest.Handler}
    }

    Delivery.enqueue(run, "worker", message(run, "blocking"))

    worker =
      start_supervised!(
        {MirrorNeuron.Runtime.AgentWorker, {run, node, [], [], self(), %{delivery_version: 2}}}
      )

    assert_receive {:handler_started, "blocking", ^worker}, 1000
    for n <- 1..7, do: Delivery.enqueue(run, "worker", message(run, "data#{n}"))

    for n <- 1..5,
        do: Delivery.enqueue(run, "worker", message(run, "cmd#{n}"), command_admitted: true)

    GenServer.cast(worker, :delivery_available)
    refute_receive {:handler_started, _, _}, 30
    send(worker, :release_handler)

    for id <- ["cmd1", "cmd2", "cmd3", "cmd4", "data1", "cmd5"] do
      assert_receive {:handler_started, ^id, ^worker}, 1000
    end

    {:ok, _flag} = Signals.subscribe(run, "errors")
    Process.exit(worker, :kill)
    assert_receive {:runtime_signal_available, "errors"}, 250
    assert {:ok, [incident]} = SignalStore.read(run, "errors", 0)
    assert incident["payload"]["correlation_id"] == "worker-exit"
    assert {:ok, %{"status" => "running"}} = RedisStore.fetch_job(run)
  end

  test "response saturation is explicit and cannot schedule responder rewarming", %{run: run} do
    alias MirrorNeuron.Runtime.JobResponse

    definition = %{
      "job_id" => run,
      "status" => "active",
      "revision" => 1,
      "owner_node" => to_string(MirrorNeuron.Cluster.NodeAdapter.self()),
      "data_dir" => "/tmp/#{run}",
      "manifest" => %{"response_service" => %{"enabled" => true}}
    }

    RedisStore.storage_command([
      "SET",
      RedisStore.storage_key(["job-definition", run]),
      Jason.encode!(definition)
    ])

    previous = Application.get_env(:mirror_neuron, :native_sdk_grpc_job_response_client)
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    parent = self()

    Application.put_env(:mirror_neuron, :native_sdk_grpc_job_response_client, fn _, request, _ ->
      attrs = Jason.decode!(request.resource_json)
      send(parent, {:native_operation, attrs["operation"]})

      if attrs["operation"] == "query",
        do: {:error, :response_service_saturated},
        else:
          {:ok,
           %Mirrorneuron.Cluster.V1.SetResourceResponse{
             resource_json: ~s({"state":"ready"}),
             version: 1
           }}
    end)

    on_exit(fn ->
      Application.put_env(:mirror_neuron, :native_sdk_grpc_job_response_client, previous)
    end)

    :ok = JobResponse.ensure_started(definition)
    assert_receive {:native_operation, "start"}, 1000

    assert {:error,
            {:retry_later,
             %{"accepted" => false, "scope" => "responses", "request_id" => "query"}}} =
             JobResponse.query_local(run, %{
               "question" => "status?",
               "request_id" => "query",
               "context" => %{}
             })

    assert_receive {:native_operation, "query"}
    [{pid, _}] = Registry.lookup(MirrorNeuron.Runtime.JobResponseRegistry, run)
    assert :sys.get_state(pid).warm_timer == nil
    refute_receive {:native_operation, "start"}, 30
    JobResponse.stop(definition)
  end
end
