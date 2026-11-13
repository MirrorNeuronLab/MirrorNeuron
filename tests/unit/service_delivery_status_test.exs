defmodule MirrorNeuron.Runtime.ServiceDeliveryStatusTest do
  use MirrorNeuron.RuntimeCase, async: false

  alias MirrorNeuron.Runtime.{Delivery, JobCoordinator}

  defmodule ServiceRunner do
    def run(_payload, config, _opts) do
      counter = :persistent_term.get(config["counter"])
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if attempt <= config["failures"] do
        {:error, %{"exit_code" => 1, "error" => "service startup failed"}}
      else
        Process.sleep(:infinity)
      end
    end
  end

  setup %{id: id} do
    counter = start_supervised!({Agent, fn -> 0 end})
    :persistent_term.put(id, counter)
    old = Application.get_env(:mirror_neuron, :message_delivery_max_attempts)
    Application.put_env(:mirror_neuron, :message_delivery_max_attempts, 2)

    on_exit(fn ->
      :persistent_term.erase(id)

      if old == nil,
        do: Application.delete_env(:mirror_neuron, :message_delivery_max_attempts),
        else: Application.put_env(:mirror_neuron, :message_delivery_max_attempts, old)
    end)

    {:ok, counter: counter}
  end

  test "exhausted auxiliary delivery commits failure instead of staying running", %{id: id} do
    assert {:ok, run_id} = MirrorNeuron.run_manifest(manifest(id, 10), await: false)
    assert {:ok, result} = MirrorNeuron.wait_for_job(run_id, 10_000)
    assert result["status"] == "failed"
    assert {:ok, owner} = MirrorNeuron.inspect_job(run_id)
    assert owner["status"] == "failed"
    assert owner["attempt"] == 1
    assert {:ok, events} = MirrorNeuron.events(run_id)
    assert Enum.any?(events, &(&1["type"] == "dead_letter"))
    assert Enum.any?(events, &(&1["type"] == "job_failed"))
    refute Enum.any?(events, &(&1["type"] == "job_clean_restart_scheduled"))
  end

  test "exhaustion waits durably while its coordinator cannot process reports", %{
    id: id,
    counter: counter
  } do
    alias MirrorNeuron.Runtime.{DeliveryChannels, Naming}
    assert {:ok, run_id} = MirrorNeuron.run_manifest(manifest(id, 10), await: false)
    wait_for(fn -> Agent.get(counter, & &1) >= 1 end, System.monotonic_time(:millisecond) + 5_000)
    coordinator = GenServer.whereis(Naming.via_job(run_id))
    :ok = :sys.suspend(coordinator)

    try do
      wait_for(
        fn ->
          DeliveryChannels.depth(run_id, Delivery.coordinator_agent_id(), :control) == {:ok, 1} and
            DeliveryChannels.depth(run_id, "service") == {:ok, 0}
        end,
        System.monotonic_time(:millisecond) + 5_000
      )

      assert Agent.get(counter, & &1) == 2
    after
      :sys.resume(coordinator)
    end

    assert {:ok, %{"status" => "failed"}} = MirrorNeuron.wait_for_job(run_id, 5_000)
  end

  test "a transient auxiliary failure keeps its delivery owner and run", %{
    id: id,
    counter: counter
  } do
    assert {:ok, run_id} = MirrorNeuron.run_manifest(manifest(id, 1), await: false)
    wait_for(fn -> Agent.get(counter, & &1) == 2 end, System.monotonic_time(:millisecond) + 5_000)
    assert {:ok, owner} = MirrorNeuron.inspect_job(run_id)
    assert owner["status"] == "running"
    assert owner["attempt"] == 1
    assert {:ok, "cancelled"} = MirrorNeuron.cancel(run_id)
  end

  test "late exhaustion cannot change paused or terminal state" do
    for status <- ["paused", "cancelled", "completed", "failed"] do
      state = %{status: status}

      assert {:noreply, ^state} =
               JobCoordinator.handle_info({:agent_delivery_exhausted, "worker", "message"}, state)
    end
  end

  defp manifest(id, failures) do
    %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => id,
      "type" => "service",
      "entrypoints" => ["service"],
      "initial_inputs" => %{"service" => [%{"start" => true}]},
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "service",
            "agent_type" => "executor",
            "config" => %{
              "runner_module" => ServiceRunner,
              "safe_to_retry" => true,
              "output_message_type" => nil,
              "counter" => id,
              "failures" => failures
            }
          }
        ],
        "edges" => []
      }
    }
  end

  defp wait_for(probe, deadline) do
    if probe.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(min(Delivery.poll_ms(), 20))
      wait_for(probe, deadline)
    end
  end
end
