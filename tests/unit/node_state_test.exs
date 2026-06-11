defmodule MirrorNeuron.Cluster.NodeStateTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.NodeState

  defmodule NodeStateStoreStub do
    def reset do
      nodes()
      |> Enum.each(fn node_name -> :persistent_term.erase({__MODULE__, :state, node_name}) end)

      :persistent_term.put({__MODULE__, :nodes}, MapSet.new())
    end

    def persist_node_state(node_name, attrs) do
      state =
        attrs
        |> Map.put("node", node_name)
        |> Map.put_new("updated_at", "2026-06-11T00:00:00Z")

      :persistent_term.put({__MODULE__, :nodes}, MapSet.put(nodes(), node_name))
      :persistent_term.put({__MODULE__, :state, node_name}, state)

      {:ok, state}
    end

    def fetch_node_state(node_name) do
      case :persistent_term.get({__MODULE__, :state, node_name}, nil) do
        nil -> {:error, "node #{node_name} state was not found"}
        state -> {:ok, state}
      end
    end

    def list_node_states do
      states =
        nodes()
        |> Enum.map(fn node_name ->
          :persistent_term.get({__MODULE__, :state, node_name}, nil)
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, states}
    end

    defp nodes, do: :persistent_term.get({__MODULE__, :nodes}, MapSet.new())
  end

  setup do
    old_store = Application.get_env(:mirror_neuron, :node_state_store)

    NodeStateStoreStub.reset()
    Application.put_env(:mirror_neuron, :node_state_store, NodeStateStoreStub)

    on_exit(fn ->
      NodeStateStoreStub.reset()
      restore_env(:node_state_store, old_store)
    end)

    :ok
  end

  test "mark_connected preserves maintenance cordon state while refreshing node data" do
    assert {:ok, _state} =
             NodeState.mark("node-a@lab", "maintenance", %{
               "scheduling_eligible" => false,
               "maintenance" => %{"enabled" => true, "reason" => "patch window"},
               "profiles" => ["old"]
             })

    assert {:ok, state} =
             NodeState.mark_connected("node-a@lab", %{
               "profiles" => ["mlx-metal"],
               "hardware" => %{"cpu" => %{"logical_processors" => 10}}
             })

    assert state["status"] == "maintenance"
    assert state["scheduling_eligible"] == false
    assert get_in(state, ["maintenance", "reason"]) == "patch window"
    assert state["profiles"] == ["mlx-metal"]
    assert NodeState.schedulable?("node-a@lab") == false
  end

  test "mark_connected preserves active drain state on heartbeat or reconnect" do
    assert {:ok, _state} =
             NodeState.mark("node-b@lab", "draining", %{
               "scheduling_eligible" => false,
               "drain" => %{
                 "status" => "blocked_no_placement",
                 "reason" => "gpu reboot",
                 "deadline_at" => "2026-05-24T10:30:00Z"
               }
             })

    assert {:ok, state} =
             NodeState.mark_connected("node-b@lab", %{
               "node_role" => "worker",
               "capabilities" => ["cuda"]
             })

    assert state["status"] == "draining"
    assert state["scheduling_eligible"] == false
    assert get_in(state, ["drain", "status"]) == "blocked_no_placement"
    assert state["capabilities"] == ["cuda"]
    assert NodeState.schedulable?("node-b@lab") == false
  end

  test "mark_connected refreshes changed address and capabilities while preserving cordon" do
    assert {:ok, _state} =
             NodeState.mark("node-gpu@10.0.0.20", "maintenance", %{
               "address" => "10.0.0.20",
               "grpc_host" => "10.0.0.20",
               "capabilities" => ["cpu"],
               "scheduling_eligible" => false,
               "maintenance" => %{"enabled" => true, "reason" => "driver upgrade"}
             })

    assert {:ok, state} =
             NodeState.mark_connected("node-gpu@10.0.0.20", %{
               "address" => "10.0.0.84",
               "grpc_host" => "10.0.0.84",
               "capabilities" => ["cuda", "nvidia", "nvidia-gb10"],
               "gpu_count" => 1
             })

    assert state["status"] == "maintenance"
    assert state["scheduling_eligible"] == false
    assert state["address"] == "10.0.0.84"
    assert state["grpc_host"] == "10.0.0.84"
    assert state["capabilities"] == ["cuda", "nvidia", "nvidia-gb10"]
    assert state["gpu_count"] == 1
    assert get_in(state, ["maintenance", "reason"]) == "driver upgrade"
    refute NodeState.schedulable?("node-gpu@10.0.0.20")
  end

  test "mark_connected preserves operator disconnect until add-node clears it" do
    assert {:ok, _state} =
             NodeState.mark("node-c@lab", "disconnected", %{
               "operator_disconnect" => true,
               "scheduling_eligible" => false
             })

    assert {:ok, disconnected} =
             NodeState.mark_connected("node-c@lab", %{
               "node_role" => "runtime",
               "profiles" => ["cuda"]
             })

    assert disconnected["status"] == "disconnected"
    assert disconnected["operator_disconnect"] == true
    assert disconnected["scheduling_eligible"] == false
    assert NodeState.operator_disconnected_state?(disconnected)
    refute NodeState.schedulable?("node-c@lab")

    assert {:ok, reconnected} =
             NodeState.mark_connected("node-c@lab", %{
               "operator_disconnect" => false
             })

    assert reconnected["status"] == "healthy"
    assert reconnected["operator_disconnect"] == false
    assert reconnected["scheduling_eligible"] == true
    refute NodeState.operator_disconnected_state?(reconnected)
    assert NodeState.schedulable?("node-c@lab")
  end

  test "direct node monitor marks preserve operator disconnect until explicitly cleared" do
    assert {:ok, _state} =
             NodeState.mark("node-d@lab", "disconnected", %{
               "operator_disconnect" => true,
               "scheduling_eligible" => false
             })

    assert {:ok, reconnecting} =
             NodeState.mark("node-d@lab", "reconnecting", %{
               "reason" => "node monitor saw nodedown"
             })

    assert reconnecting["status"] == "disconnected"
    assert reconnecting["operator_disconnect"] == true
    assert reconnecting["scheduling_eligible"] == false

    assert {:ok, offline} = NodeState.mark("node-d@lab", "offline")
    assert offline["status"] == "disconnected"
    assert offline["operator_disconnect"] == true
    assert offline["scheduling_eligible"] == false

    assert {:ok, cleared} =
             NodeState.mark("node-d@lab", "healthy", %{
               "operator_disconnect" => false,
               "scheduling_eligible" => true
             })

    assert cleared["status"] == "healthy"
    assert cleared["operator_disconnect"] == false
    assert cleared["scheduling_eligible"] == true
  end

  test "schedulable_state rejects operator and failure states" do
    refute NodeState.schedulable_state?(%{
             "status" => "maintenance",
             "scheduling_eligible" => false
           })

    refute NodeState.schedulable_state?(%{"status" => "draining", "scheduling_eligible" => false})
    refute NodeState.schedulable_state?(%{"status" => "healthy", "scheduling_eligible" => false})
    refute NodeState.schedulable_state?(%{"status" => "offline"})
    refute NodeState.schedulable_state?(%{"status" => "quarantined"})
    assert NodeState.schedulable_state?(%{"status" => "healthy"})
    assert NodeState.schedulable_state?(%{"status" => "joining"})
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
