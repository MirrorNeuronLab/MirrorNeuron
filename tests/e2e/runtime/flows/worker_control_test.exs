defmodule MirrorNeuron.Runtime.FlowsTest.WorkerControlTest do
  use MirrorNeuron.RuntimeFlowCase, async: false

  @moduletag skip: is_nil(System.get_env("MN_FLOW_REDIS_URL"))

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Persistence.SignalStore
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.Signals

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
