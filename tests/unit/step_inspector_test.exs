defmodule MirrorNeuron.Runtime.StepInspectorTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runtime.StepInspector

  test "an async inspection observes a busy owner without asking its mailbox" do
    job = "inspect-#{System.unique_integer([:positive])}"
    parent = self()

    worker =
      spawn(fn ->
        {:ok, _} =
          Horde.Registry.register(MirrorNeuron.DistributedRegistry, {:agent, job, "worker"}, nil)

        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive :registered
    assert {:ok, _} = StepInspector.start(self(), job, "step", "inspection", ["worker", "absent"])
    assert_receive {:workflow_step_inspected, "step", "inspection", result}, 1_000
    assert result == %{"worker" => "alive", "absent" => "dead"}
    assert Process.alive?(worker)
  end
end
