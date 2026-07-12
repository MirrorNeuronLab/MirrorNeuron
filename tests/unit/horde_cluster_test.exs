defmodule MirrorNeuron.Runtime.HordeClusterTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runtime.HordeCluster

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
    state = %{enabled: true, refresh_ms: 10_000, refresh_timer_ref: nil}

    assert {:noreply, refreshed} = HordeCluster.handle_info(:refresh, state)
    first_ref = refreshed.refresh_timer_ref
    assert is_integer(Process.read_timer(first_ref))

    assert {:noreply, coalesced} =
             HordeCluster.handle_info({:nodeup, :"runtime@127.0.0.2"}, refreshed)

    second_ref = coalesced.refresh_timer_ref
    refute second_ref == first_ref
    assert Process.read_timer(first_ref) == false
    assert is_integer(Process.read_timer(second_ref))

    Process.cancel_timer(second_ref)
  end
end
