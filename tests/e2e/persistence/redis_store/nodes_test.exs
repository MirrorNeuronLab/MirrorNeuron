defmodule MirrorNeuron.Persistence.RedisStore.NodesTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore

  test "bundle archive and node state round-trip nested data" do
    fingerprint = "bundle-#{System.unique_integer([:positive])}"

    assert {:ok, archive} =
             RedisStore.persist_bundle_archive(fingerprint, %{
               "graph_id" => "graph",
               "files" => [%{"path" => "payload/main.py", "data" => "print(1)"}]
             })

    assert archive["fingerprint"] == fingerprint
    assert {:ok, fetched} = RedisStore.fetch_bundle_archive(fingerprint)
    assert get_in(fetched, ["files", Access.at(0), "path"]) == "payload/main.py"

    assert {:ok, state} =
             RedisStore.persist_node_state("node-a@test", %{
               status: :healthy,
               capacities: %{default: 2},
               flags: [:runtime]
             })

    assert state["status"] == :healthy
    assert state["capacities"]["default"] == 2
    assert state["flags"] == [:runtime]

    assert {:ok, fetched_state} = RedisStore.fetch_node_state("node-a@test")
    assert fetched_state["status"] == "healthy"
    assert fetched_state["flags"] == ["runtime"]

    assert {:ok, states} = RedisStore.list_node_states()
    assert Enum.any?(states, &(&1["node"] == "node-a@test"))
  end

  test "node state listing compacts missing indexes but preserves unreadable state", %{
    namespace: namespace
  } do
    missing_node = "missing-node@test"
    corrupt_node = "corrupt-node@test"

    assert {:ok, 2} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["nodes"]),
               missing_node,
               corrupt_node
             ])

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["node", corrupt_node, "state"]),
               "not-json"
             ])

    assert {:ok, states} = RedisStore.list_node_states()
    refute Enum.any?(states, &(&1["node"] in [missing_node, corrupt_node]))

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["nodes"]),
               missing_node
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["nodes"]),
               corrupt_node
             ])
  end
end
