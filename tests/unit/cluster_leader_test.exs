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

    assert {:ok, %{is_leader: false}} = Leader.init(:ok)
    refute_receive :campaign, 600
  end

  test "network-only nodes ignore stray campaign messages" do
    Application.put_env(:mirror_neuron, :network_only, true)

    state = %{is_leader: false, node_name: to_string(Node.self()), sweep_ref: nil}
    assert {:noreply, ^state} = Leader.handle_info(:campaign, state)
  end
end
