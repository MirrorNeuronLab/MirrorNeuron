defmodule MirrorNeuron.ClusterLeaderTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.Leader

  setup do
    previous = Application.get_env(:mirror_neuron, :network_only)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mirror_neuron, :network_only)
      else
        Application.put_env(:mirror_neuron, :network_only, previous)
      end
    end)

    :ok
  end

  test "network-only nodes do not schedule leader campaigns" do
    Application.put_env(:mirror_neuron, :network_only, true)

    assert {:ok, %{is_leader: false, campaign_ref: nil, campaign_token: nil}} =
             Leader.init(:ok)

    refute_receive :campaign, 600
  end

  test "network-only nodes ignore stray campaign messages" do
    Application.put_env(:mirror_neuron, :network_only, true)

    state = %{is_leader: false, node_name: to_string(Node.self()), sweep_ref: nil}
    assert {:noreply, ^state} = Leader.handle_info(:campaign, state)
  end

  test "repeated node-down notices coalesce into one delayed sweep" do
    node_name = "runtime-b@127.0.0.1"
    state = leader_state()

    assert {:noreply, first_state} = Leader.handle_cast({:node_down, node_name}, state)
    assert %{^node_name => {first_ref, first_token}} = first_state.node_sweep_timers

    assert {:noreply, second_state} =
             Leader.handle_cast({:node_down, node_name}, first_state)

    assert %{^node_name => {second_ref, second_token}} = second_state.node_sweep_timers
    refute first_ref == second_ref
    refute first_token == second_token
    assert Process.read_timer(first_ref) == false
    assert map_size(second_state.node_sweep_timers) == 1

    assert :ok = Leader.terminate(:normal, %{second_state | is_leader: false})
    assert Process.read_timer(second_ref) == false
  end

  defp leader_state do
    %{
      is_leader: true,
      node_name: to_string(Node.self()),
      campaign_ref: nil,
      campaign_token: nil,
      sweep_ref: nil,
      sweep_token: nil,
      node_sweep_timers: %{}
    }
  end
end
