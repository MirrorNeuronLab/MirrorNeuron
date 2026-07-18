defmodule MirrorNeuron.OperationStoreTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.OperationStore

  test "persists replayable item progress and allows only one runner claim" do
    if redis_available?() do
      with_isolated_redis_namespace(fn ->
        targets = [
          %{"id" => "job-a", "job_id" => "job-a"},
          %{"id" => "job-b", "job_id" => "job-b"}
        ]

        assert {:ok, operation} = OperationStore.create("cancel_all_jobs", targets)
        operation_id = operation["operation_id"]

        assert :ok = OperationStore.claim_runner(operation_id, "runner-a", 5_000)
        assert {:error, :claimed} = OperationStore.claim_runner(operation_id, "runner-b", 5_000)

        assert {:ok, _item, _event} = OperationStore.start_item(operation_id, hd(targets))

        assert {:ok, _item, _event} =
                 OperationStore.finish_item(
                   operation_id,
                   hd(targets),
                   "cancellation_pending",
                   %{"message" => "cleanup queued"}
                 )

        assert {:ok, replay} = OperationStore.read_events(operation_id)
        assert Enum.map(replay, & &1["sequence"]) == Enum.to_list(1..length(replay))
        assert Enum.any?(replay, &(&1["type"] == "item_started"))
        assert Enum.any?(replay, &(&1["type"] == "item_deferred"))

        assert {:ok, hydrated} = OperationStore.fetch(operation_id)
        assert hydrated["items"]["job-a"]["status"] == "cancellation_pending"
        assert hydrated["counters"]["deferred"] == 1
      end)
    end
  end

  defp redis_available? do
    case Process.whereis(MirrorNeuron.Redis.Connection) do
      nil ->
        false

      _pid ->
        match?({:ok, "PONG"}, Redix.command(MirrorNeuron.Redis.Connection, ["PING"]))
    end
  catch
    :exit, _reason -> false
  end

  defp with_isolated_redis_namespace(fun) do
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    namespace = "mirror_neuron_operation_store_test_#{System.unique_integer([:positive])}"

    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_REDIS_NAMESPACE", namespace)

    try do
      fun.()
    after
      restore_env(:redis_namespace, old_namespace)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
