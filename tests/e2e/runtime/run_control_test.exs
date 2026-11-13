defmodule MirrorNeuron.RuntimeTest.ControlledService do
  def control_profile(_), do: MirrorNeuron.Runner.ControlProfile.service()
  def prepared_key(_, :pause), do: :test_service
  def prepared_key(_, _), do: nil

  def stop_prepared(_) do
    send(__MODULE__, {:service_stopping, self()})

    receive do
      {:stop_result, result} -> result
    after
      5_000 -> {:error, :missing_stop_receipt}
    end
  end

  def run(_, config, opts) do
    lifecycle = MirrorNeuron.Runner.ServiceLifecycle.new(config, opts)
    send(__MODULE__, {:service_started, self(), lifecycle.receipt})
    serve(lifecycle)
  end

  defp serve(lifecycle) do
    receive do
      :ready ->
        serve(MirrorNeuron.Runner.ServiceLifecycle.publish(lifecycle, "serving", ""))

      :fail ->
        serve(MirrorNeuron.Runner.ServiceLifecycle.publish(lifecycle, "failed", "test_failure"))
    end
  end
end

defmodule MirrorNeuron.Runtime.RunControlTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false
  alias MirrorNeuron.Runtime.RunControl
  alias MirrorNeuron.Persistence.{RunControlStore, RedisStore}
  alias MirrorNeuron.RuntimeTest.ControlledService, as: Service

  setup do
    Process.register(self(), Service)
    :ok
  end

  defp service do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "uniform_control",
      "policies" => %{
        "resource_allocation" => %{"mode" => "shared", "cpu_cores" => 1, "memory_mb" => 512}
      },
      "type" => "service",
      "entrypoints" => ["service"],
      "initial_inputs" => %{"service" => [%{}]},
      "edges" => [],
      "nodes" => [
        %{
          "node_id" => "service",
          "agent_type" => "executor",
          "config" => %{"runner_module" => Service, "output_message_type" => nil}
        }
      ]
    }

    {:ok, run} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(run)
    assert_receive {:service_started, process, receipt}, 5_000
    send(process, :ready)

    wait_until(
      fn ->
        {:ok, state} = RedisStore.fetch_job(run)
        MirrorNeuron.Runtime.RunLifecycle.ready?(state["lifecycle"])
      end,
      5_000
    )

    {run, receipt}
  end

  defp await_control(run, id, status) do
    wait_until(fn -> match?({:ok, %{"status" => ^status}}, RunControl.get(run, id)) end, 5_000)
    {:ok, receipt} = RunControl.get(run, id)
    receipt
  end

  test "pause then resume waits for physical cleanup and generation-specific readiness" do
    {run, old_receipt} = service()
    assert {:ok, _} = RunControl.submit(run, "pause", "pause-1")
    assert_receive {:service_stopping, cleanup}, 5_000
    assert {:ok, _} = RunControl.submit(run, "resume", "resume-1")
    assert {:ok, %{"status" => "queued"}} = RunControl.get(run, "resume-1")
    refute_receive {:service_started, _, _}
    send(cleanup, {:stop_result, :ok})
    await_control(run, "pause-1", "completed")
    assert_receive {:service_started, process, current}, 5_000
    assert current["control_generation"] == "resume-1"
    coordinator = job_coordinator_pid(run)
    stale = Map.merge(old_receipt, %{"state" => "serving", "sequence" => 100})
    send(coordinator, {:agent_event, "service", "service_lifecycle", %{"details" => stale}})
    :sys.get_state(coordinator)
    assert {:ok, %{"status" => "executing"}} = RunControl.get(run, "resume-1")
    send(process, :ready)
    await_control(run, "resume-1", "completed")
    assert {:ok, %{"status" => "completed"}} = RunControl.submit(run, "resume", "resume-1")
    assert {:error, {:run_control, "conflict"}} = RunControl.submit(run, "pause", "resume-1")
    refute_receive {:service_started, _, _}
  end

  test "stop supersedes readiness wait and confirms cleanup" do
    {run, _} = service()
    {:ok, _} = RunControl.submit(run, "pause", "pause")
    assert_receive {:service_stopping, cleanup}, 5_000
    send(cleanup, {:stop_result, :ok})
    await_control(run, "pause", "completed")
    {:ok, _} = RunControl.submit(run, "resume", "resume")
    assert_receive {:service_started, _, _}, 5_000
    {:ok, _} = RunControl.submit(run, "cancel", "stop")
    await_control(run, "resume", "superseded")
    await_control(run, "stop", "completed")

    assert {:ok, %{"status" => "cancelled", "finalization_id" => fence}} =
             RedisStore.fetch_job(run)

    assert is_binary(fence) and byte_size(fence) > 0
  end

  test "driver restart observes the original effect without dispatching another service" do
    {run, _} = service()
    {:ok, _} = RunControl.submit(run, "pause", "pause")
    assert_receive {:service_stopping, cleanup}, 5_000
    send(cleanup, {:stop_result, :ok})
    await_control(run, "pause", "completed")
    {:ok, _} = RunControl.submit(run, "resume", "resume")
    assert_receive {:service_started, process, _}, 5_000
    [{driver, _}] = Registry.lookup(MirrorNeuron.Runtime.RunControl.Registry, run)
    Process.exit(driver, :kill)
    send(process, :ready)
    await_control(run, "resume", "completed")
    refute_receive {:service_started, _, _}
  end

  test "failed readiness becomes a terminal command receipt" do
    {run, _} = service()
    {:ok, _} = RunControl.submit(run, "pause", "pause")
    assert_receive {:service_stopping, cleanup}, 5_000
    send(cleanup, {:stop_result, :ok})
    await_control(run, "pause", "completed")
    {:ok, _} = RunControl.submit(run, "resume", "resume")
    assert_receive {:service_started, process, _}, 5_000
    send(process, :fail)
    assert await_control(run, "resume", "failed")["error"]["code"] == "service_readiness_failed"
  end

  test "journal claims are atomic and terminal receipts are monotonic" do
    {run, _} = service()
    assert {:ok, _} = RunControlStore.enqueue(run, "pause", "atomic", false)

    results =
      1..12
      |> Task.async_stream(fn _ -> RunControlStore.claim(run, "atomic") end)
      |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, %{"claimed" => true}}}, &1)) == 1
    assert {:ok, _} = RunControlStore.update(run, "atomic", %{"status" => "failed"})

    assert {:ok, %{"status" => "failed"}} =
             RunControlStore.update(run, "atomic", %{"status" => "executing"})
  end

  test "recent history rotation retains request idempotency" do
    {run, _} = service()

    for index <- 1..130 do
      id = "saved-#{index}"
      {:ok, _} = RunControlStore.enqueue(run, "pause", id, false)
      {:ok, _} = RunControlStore.update(run, id, %{"status" => "completed"})
    end

    assert {:ok, %{"status" => "completed"}} =
             RunControlStore.enqueue(run, "pause", "saved-1", false)

    assert {:ok, %{"status" => "completed"}} = RunControlStore.get(run, "saved-1")
  end

  test "a failed pause blocks resume without blocking another run" do
    {first, _} = service()
    {second, _} = service()
    {:ok, _} = RunControl.submit(first, "pause", "first-pause")
    assert_receive {:service_stopping, cleanup}, 5_000
    {:ok, _} = RunControl.submit(first, "resume", "first-resume")
    {:ok, _} = RunControl.submit(second, "resume", "second-resume")
    await_control(second, "second-resume", "completed")
    send(cleanup, {:stop_result, {:error, :injected}})
    await_control(first, "first-pause", "failed")
    await_control(first, "first-resume", "failed")
    refute_receive {:service_started, _, _}
  end

  test "control input is validated before entering the journal" do
    {run, _} = service()
    assert {:error, :invalid_run_control} = RunControl.submit(run, "resume", "guard", true)

    assert {:error, :invalid_run_control} =
             RunControl.submit(run, "pause", String.duplicate("x", 129))

    assert {:error, :invalid_run_control} = RunControl.get(run, "")
    assert {:ok, []} = RunControlStore.list(run)
  end
end
