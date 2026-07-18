defmodule MirrorNeuron.Persistence.RedisRoutingTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore

  @namespace "mirror_neuron_redis_routing_test"
  @test_pid_name :redis_routing_test_pid

  defmodule ClusterNodeAdapterStub do
    @test_pid_name :redis_routing_test_pid

    def reset, do: :persistent_term.put({__MODULE__, :list}, [])
    def self, do: :control@lab
    def list, do: :persistent_term.get({__MODULE__, :list}, [])
    def put_list(nodes), do: :persistent_term.put({__MODULE__, :list}, nodes)
    def connect(_node), do: true
    def disconnect(_node), do: true
    def set_cookie(_node, _cookie), do: :ok

    def rpc_call(node, module, function, args, timeout) do
      send(Process.whereis(@test_pid_name), {:rpc_call, node, module, function, args, timeout})
      {:badrpc, :unexpected_call}
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)

    old_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_forward_primary = System.get_env("MN_REDIS_FORWARD_PRIMARY")

    ClusterNodeAdapterStub.reset()
    Application.put_env(:mirror_neuron, :cluster_node_adapter, ClusterNodeAdapterStub)
    Application.put_env(:mirror_neuron, :redis_namespace, @namespace)
    System.put_env("MN_REDIS_NAMESPACE", @namespace)
    # Retain the removed legacy flag to make this regression explicit.
    System.put_env("MN_REDIS_FORWARD_PRIMARY", "true")

    on_exit(fn ->
      ClusterNodeAdapterStub.reset()
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      restore_env(:cluster_node_adapter, old_adapter)
      restore_env(:redis_namespace, old_namespace)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_system_env("MN_REDIS_FORWARD_PRIMARY", old_forward_primary)
    end)
  end

  test "never forwards Redis commands over a BEAM peer" do
    ClusterNodeAdapterStub.put_list([:primary@lab])

    assert {:error, _reason} = RedisStore.fetch_job("missing-job")

    refute_receive {:rpc_call, :primary@lab, _, _, _, _}, 100
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
