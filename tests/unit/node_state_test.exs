defmodule MirrorNeuron.Cluster.NodeStateTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.NodeState

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> raise "Redis must be running for node state tests"
    end

    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")

    namespace = "mirror_neuron_node_state_test_#{System.unique_integer([:positive])}"
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_REDIS_NAMESPACE", namespace)

    on_exit(fn ->
      cleanup_namespace(namespace)
      restore_env(:redis_namespace, old_namespace)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
    end)

    {:ok, namespace: namespace}
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

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
        :ok

      _ ->
        :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
