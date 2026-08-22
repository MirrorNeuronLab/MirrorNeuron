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
      %{"node" => "mn4@192.168.4.175", "status" => "disconnected"},
      %{
        "node" => "mn5@192.168.4.176",
        "status" => "healthy",
        "connection_mode" => "federated"
      }
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
      refresh_token: nil,
      memberships: %{DemoHorde => {:old_pid, MapSet.new()}}
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
    assert coalesced.memberships == %{}

    assert :ok = HordeCluster.terminate(:normal, coalesced)
    assert Process.read_timer(second_ref) == false
  end

  test "unchanged Horde membership is not synchronously rewritten on every refresh" do
    test_pid = self()

    set_members = fn horde, members ->
      send(test_pid, {:set_members, horde, members})
      :ok
    end

    whereis = fn _horde -> :stable_horde_pid end
    nodes = [:node_a, :node_b]

    memberships =
      HordeCluster.refresh_horde_memberships(
        [DemoRegistry, DemoSupervisor],
        nodes,
        %{},
        set_members: set_members,
        whereis: whereis
      )

    assert_receive {:set_members, DemoRegistry,
                    [{DemoRegistry, :node_a}, {DemoRegistry, :node_b}]}

    assert_receive {:set_members, DemoSupervisor,
                    [{DemoSupervisor, :node_a}, {DemoSupervisor, :node_b}]}

    assert memberships ==
             HordeCluster.refresh_horde_memberships(
               [DemoRegistry, DemoSupervisor],
               Enum.reverse(nodes),
               memberships,
               set_members: set_members,
               whereis: whereis
             )

    refute_receive {:set_members, _, _}
  end

  test "a failed Horde update does not block other Horde membership updates" do
    test_pid = self()

    set_members = fn
      FailingHorde, _members ->
        exit(:timeout)

      horde, members ->
        send(test_pid, {:set_members, horde, members})
        :ok
    end

    memberships =
      HordeCluster.refresh_horde_memberships(
        [FailingHorde, HealthyHorde],
        [:node_a],
        %{},
        set_members: set_members,
        whereis: fn horde -> {horde, :pid} end
      )

    assert_receive {:set_members, HealthyHorde, [{HealthyHorde, :node_a}]}
    refute Map.has_key?(memberships, FailingHorde)
    assert Map.has_key?(memberships, HealthyHorde)
  end

  test "a restarted Horde process forces membership to be applied again" do
    test_pid = self()

    set_members = fn horde, members ->
      send(test_pid, {:set_members, horde, members})
      :ok
    end

    initial =
      HordeCluster.refresh_horde_memberships(
        [DemoHorde],
        [:node_a],
        %{},
        set_members: set_members,
        whereis: fn _horde -> :first_pid end
      )

    assert_receive {:set_members, DemoHorde, [{DemoHorde, :node_a}]}

    HordeCluster.refresh_horde_memberships(
      [DemoHorde],
      [:node_a],
      initial,
      set_members: set_members,
      whereis: fn _horde -> :replacement_pid end
    )

    assert_receive {:set_members, DemoHorde, [{DemoHorde, :node_a}]}
  end
end
