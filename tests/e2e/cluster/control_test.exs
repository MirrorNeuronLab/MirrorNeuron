defmodule MirrorNeuron.Cluster.ControlTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.Control

  defmodule RPCStub do
    def call(node, module, function, args, timeout) do
      send(self(), {:rpc_call, node, module, function, args, timeout})

      case {module, function, args} do
        {MirrorNeuron.Execution.LeaseManager, :stats, []} ->
          case node do
            :mn1@test -> %{"default" => %{"capacity" => 2}}
            :mn2@test -> %{"default" => %{"capacity" => 4}}
            _ -> {:badrpc, :nodedown}
          end

        {MirrorNeuron.Cluster.Manager, :nodes, []} ->
          [%{name: "mn1@test"}, %{name: "mn2@test"}]

        _ ->
          {:ok, :proxied}
      end
    end
  end

  setup do
    original_nodes = Node.list()
    original_env = System.get_env("MIRROR_NEURON_CLUSTER_NODES")
    original_adapter = Application.get_env(:mirror_neuron, :rpc_adapter)

    Application.put_env(:mirror_neuron, :rpc_adapter, RPCStub)
    System.put_env("MIRROR_NEURON_CLUSTER_NODES", "mn1@test,mn2@test,offline@test")

    on_exit(fn ->
      if original_env do
        System.put_env("MIRROR_NEURON_CLUSTER_NODES", original_env)
      else
        System.delete_env("MIRROR_NEURON_CLUSTER_NODES")
      end

      if original_adapter do
        Application.put_env(:mirror_neuron, :rpc_adapter, original_adapter)
      else
        Application.delete_env(:mirror_neuron, :rpc_adapter)
      end
    end)

    {:ok, original_nodes: original_nodes}
  end

  test "selects only connected runtime nodes", %{original_nodes: _original_nodes} do
    assert [:mn1@test, :mn2@test] = Control.runtime_nodes([:mn1@test, :mn2@test, :offline@test])
  end

  test "proxies calls to the first available runtime node" do
    assert [%{name: "mn1@test"}, %{name: "mn2@test"}] =
             Control.call(MirrorNeuron.Cluster.Manager, :nodes, [], 1_000, [:mn1@test, :mn2@test])

    assert_received {:rpc_call, :mn1@test, MirrorNeuron.Cluster.Manager, :nodes, [], 1_000}
  end
end
