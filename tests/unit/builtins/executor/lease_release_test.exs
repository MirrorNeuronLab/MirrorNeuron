defmodule MirrorNeuron.Builtins.Executor.LeaseReleaseTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Builtins.Executor
  alias MirrorNeuron.Execution.LeaseManager

  defmodule CrashingRunner do
    def run(_, _, _), do: raise("runner crashed")
  end

  test "a raised runner failure still releases the acquired pool lease" do
    manager = start_supervised!({LeaseManager, name: nil, capacities: %{"default" => 1}})

    node = %{
      node_id: "worker",
      config: %{"runner_module" => CrashingRunner, "lease_manager" => manager}
    }

    assert {:ok, state} = Executor.init(node)

    context = %{
      job_id: "job",
      node: node,
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp"
    }

    message = MirrorNeuron.Message.new("job", "source", "worker", "input", %{})

    assert_raise RuntimeError, "runner crashed", fn ->
      Executor.handle_message(message, state, context)
    end

    assert %{"default" => %{in_use: 0}} = LeaseManager.stats(manager)
    assert_receive {:agent_event, "worker", :executor_lease_released, %{}}
  end
end
