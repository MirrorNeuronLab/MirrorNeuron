defmodule MirrorNeuron.Runtime.ContextMemoryTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.ContextMemory

  test "scope matches the versioned Membrane wire contract without glob injection" do
    assert {:ok, "mn:context:working:v1:{3:job:3:run}:"} = ContextMemory.prefix("job", "run")
    assert {:error, :invalid_context_scope} = ContextMemory.prefix("job*", "run")
    assert ContextMemory.prefix("job", "run2") != ContextMemory.prefix("job2", "run")
  end

  test "cleanup fences writes, pages bounded keys, and keeps its tombstone" do
    {:ok, scope} = ContextMemory.prefix("job", "run")
    parent = self()

    command = fn args ->
      send(parent, {:command, args})

      case args do
        ["SET", _, "1"] ->
          {:ok, "OK"}

        ["SCAN", "0", "MATCH", _, "COUNT", "128"] ->
          {:ok, ["7", [scope <> "card:one", scope <> "cancelled"]]}

        ["SCAN", "7", "MATCH", _, "COUNT", "128"] ->
          {:ok, ["0", [scope <> "event:two"]]}

        ["UNLINK" | keys] ->
          {:ok, length(keys)}
      end
    end

    assert :ok = ContextMemory.clear(scope, command)
    assert_receive {:command, ["SET", _, "1"]}
    assert_receive {:command, ["UNLINK", key]}
    assert key == scope <> "card:one"
    assert_receive {:command, ["UNLINK", key]}
    assert key == scope <> "event:two"
    cancelled_key = scope <> "cancelled"
    refute_receive {:command, ["UNLINK", ^cancelled_key]}
  end

  test "fencing failure prevents cleanup from appearing successful" do
    assert {:error, :context_memory_fence_failed} =
             ContextMemory.clear("scope:", fn _ -> {:error, :offline} end)
  end
end
