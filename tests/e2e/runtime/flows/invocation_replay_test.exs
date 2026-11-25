defmodule MirrorNeuron.Runtime.FlowsTest.InvocationReplayTest do
  use MirrorNeuron.RuntimeFlowCase, async: false

  @moduletag skip: is_nil(System.get_env("MN_FLOW_REDIS_URL"))

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.DeliveryStore
  alias MirrorNeuron.Persistence.SignalStore
  alias MirrorNeuron.Runtime.AgentWorker
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.InvocationOutbox

  defmodule BranchingHandler do
    use MirrorNeuron.AgentTemplate
    def init(_node), do: {:ok, %{}}

    def handle_message(message, _state, context) do
      id = Message.id(message)
      send(context.coordinator, {:handler_ran, id, self()})

      case id do
        "route" -> {:ok, %{branch: "original"}, [{:emit, "result", %{}}]}
        "switch" -> {:ok, %{branch: "later"}, []}
      end
    end
  end

  test "outbox replays the producing invocation's state and actions without repeating its handler",
       %{
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

    assert {:checkpointed, %{value: 1}, [{:noop}], 1, _} =
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

  test "after restart a deferred output follows its recorded branch while the worker keeps newer state",
       %{run: run} do
    node = %{
      node_id: "worker",
      agent_type: "module",
      type: "generic",
      role: "worker",
      config: %{"module" => BranchingHandler}
    }

    edges =
      for target <- ~w(original later) do
        %{
          edge_id: target,
          from_node: "worker",
          to_node: target,
          message_type: "result",
          routing_mode: "first_match",
          conditions: %{"path" => "state.branch", "value" => target}
        }
      end

    runtime = %{delivery_version: 2, backpressure_by_agent: %{"original" => [max_queue_depth: 1]}}
    worker = fn recovery -> {AgentWorker, {run, node, edges, [], self(), runtime, recovery}} end

    # Hold the output queue full while another command advances the durable checkpoint.
    blocker = Message.new(run, "source", "original", "occupied", %{})
    assert {:ok, _} = Delivery.enqueue(run, "original", blocker)
    assert {:ok, [held]} = Delivery.read(run, "original", "sink")
    assert {:ok, _} = Delivery.enqueue(run, "worker", message(run, "route"))
    first = start_supervised!(worker.(%{}))
    assert_receive {:handler_ran, "route", ^first}, 2_000
    assert_receive {:agent_event, "worker", :route_selected, %{"to" => "original"}}, 2_000

    assert {:ok, _} =
             Delivery.enqueue(run, "worker", message(run, "switch"), command_admitted: true)

    GenServer.cast(first, :delivery_available)
    assert_receive {:agent_event, "worker", :message_acked, %{"message_id" => "switch"}}, 2_000
    stop_supervised!({:agent_worker, run, "worker"})

    assert :ok = Delivery.ack(run, "original", "sink", held)
    restarted = start_supervised!(worker.(%{"reclaim_deliveries" => true}))
    assert_receive {:agent_event, "worker", :message_acked, %{"message_id" => "route"}}, 3_000
    assert {:ok, [output]} = Delivery.read(run, "original", "sink")
    assert Message.causation_id(output.message) == "route"
    assert {:ok, []} = Delivery.read(run, "later", "sink")

    assert %{processed_messages: 2, local_state: %{delegate_state: %{branch: "later"}}} =
             :sys.get_state(restarted)

    refute_received {:handler_ran, "route", ^restarted}
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
end
