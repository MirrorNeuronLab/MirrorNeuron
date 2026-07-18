defmodule MirrorNeuron.Runtime.HordeClusterTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runtime.HordeCluster

  defmodule NodeStateStoreStub do
    def reset, do: :persistent_term.put({__MODULE__, :states}, [])
    def put_states(states), do: :persistent_term.put({__MODULE__, :states}, states)
    def list_node_states, do: {:ok, :persistent_term.get({__MODULE__, :states}, [])}
  end

  setup do
    old_store = Application.get_env(:mirror_neuron, :node_state_store)
    old_cluster_nodes = System.get_env("MN_CLUSTER_NODES")

    NodeStateStoreStub.reset()
    Application.put_env(:mirror_neuron, :node_state_store, NodeStateStoreStub)
    System.delete_env("MN_CLUSTER_NODES")

    on_exit(fn ->
      NodeStateStoreStub.reset()

      if old_store,
        do: Application.put_env(:mirror_neuron, :node_state_store, old_store),
        else: Application.delete_env(:mirror_neuron, :node_state_store)

      if old_cluster_nodes,
        do: System.put_env("MN_CLUSTER_NODES", old_cluster_nodes),
        else: System.delete_env("MN_CLUSTER_NODES")
    end)
  end

  test "configured_nodes merges durable healthy peers with environment seeds" do
    System.put_env("MN_CLUSTER_NODES", "mn1@192.168.6.28")

    NodeStateStoreStub.put_states([
      %{"node" => "mn2@192.168.4.173", "status" => "healthy"},
      %{"node" => "mn3@192.168.4.174", "status" => "joining"},
      %{"node" => "mn4@192.168.4.175", "status" => "disconnected"}
    ])

    assert HordeCluster.configured_nodes() == [
             :"mn1@192.168.6.28",
             :"mn2@192.168.4.173",
             :"mn3@192.168.4.174"
           ]
  end

  test "member_nodes keeps runtime peers and excludes transient probe nodes" do
    self_node = :"mirror_neuron@192.168.6.28"

    nodes =
      HordeCluster.member_nodes(
        self_node,
        [
          :"mirror_neuron@192.168.4.173",
          :"mn_probe@127.0.0.1"
        ],
        []
      )

    assert self_node in nodes
    assert :"mirror_neuron@192.168.4.173" in nodes
    refute :"mn_probe@127.0.0.1" in nodes
  end

  test "member_nodes includes configured peers with different runtime name prefixes" do
    self_node = :"mn1@192.168.6.28"

    nodes =
      HordeCluster.member_nodes(
        self_node,
        [
          :"mn2@192.168.4.173",
          :"random_probe@127.0.0.1"
        ],
        [:"mn2@192.168.4.173"]
      )

    assert self_node in nodes
    assert :"mn2@192.168.4.173" in nodes
    refute :"random_probe@127.0.0.1" in nodes
  end

  test "horde_members builds Horde member tuples" do
    assert HordeCluster.horde_members(MyHorde, [:node_a, :node_b]) == [
             {MyHorde, :node_a},
             {MyHorde, :node_b}
           ]
  end

  test "refreshes periodically and coalesces node events into one timer" do
    state = %{
      enabled: true,
      refresh_ms: 10_000,
      refresh_timer_ref: nil,
      refresh_token: nil
    }

    assert {:noreply, refreshed} =
             HordeCluster.handle_info({:nodeup, :"runtime@127.0.0.2"}, state)

    first_ref = refreshed.refresh_timer_ref
    assert is_integer(Process.read_timer(first_ref))

    assert {:noreply, coalesced} =
             HordeCluster.handle_info({:nodedown, :"runtime@127.0.0.2"}, refreshed)

    second_ref = coalesced.refresh_timer_ref
    refute second_ref == first_ref
    refute coalesced.refresh_token == refreshed.refresh_token
    assert Process.read_timer(first_ref) == false
    assert is_integer(Process.read_timer(second_ref))

    assert :ok = HordeCluster.terminate(:normal, coalesced)
    assert Process.read_timer(second_ref) == false
  end
end
