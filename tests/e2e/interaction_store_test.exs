defmodule MirrorNeuron.Persistence.InteractionStoreTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runtime.Interactions
  alias MirrorNeuron.Persistence.InteractionStore

  setup_all do
    Application.ensure_all_started(:redix)
    unless Process.whereis(MirrorNeuron.Redis.Connection), do: start_supervised!({Redix, {"redis://127.0.0.1:6379", [name: MirrorNeuron.Redis.Connection]}})
    unless Process.whereis(MirrorNeuron.Runtime.EventRegistry), do: start_supervised!({Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry})
    :ok
  end

  setup do
    old = System.get_env("MN_REDIS_NAMESPACE")
    System.put_env("MN_REDIS_NAMESPACE", "interaction-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> if old, do: System.put_env("MN_REDIS_NAMESPACE", old), else: System.delete_env("MN_REDIS_NAMESPACE") end)
    :ok
  end

  defp create(extra \\ %{}) do
    record = Map.merge(%{"id" => "review-1", "kind" => "approval",
      "scope" => %{"job_id" => "job-1", "execution_id" => "original-run"},
      "presentation" => %{"widget" => "confirmation", "title" => "Approve?"},
      "options" => [%{"id" => "yes", "label" => "Allow", "action" => "approve"}], "fields" => []}, extra)
    Interactions.command(%{"op" => "create", "record" => record})
  end
  defp respond(id \\ "command-1") do
    Interactions.command(%{"op" => "respond", "id" => "review-1", "expected_revision" => 1,
      "command_id" => id, "answer" => %{"option_id" => "yes"}})
  end

  test "snapshot cursor closes subscription race and duplicate commands have one receipt" do
    {:ok, before} = InteractionStore.snapshot()
    {:ok, created} = create()
    {:ok, duplicate} = create()
    assert created == duplicate
    {:ok, received} = respond()
    assert received["effect"] == "not_started"
    assert received["scope"]["execution_id"] == "original-run"
    assert {:ok, ^received} = respond()
    {:ok, events} = InteractionStore.events(before["cursor"])
    assert Enum.map(events, & &1["data"]["state"]) == ["pending", "responded"]
    assert {:error, "revision_conflict"} = respond("different-command")
  end

  test "concurrent decisions have exactly one winner" do
    {:ok, _} = create()
    results = 1..8 |> Task.async_stream(fn n -> respond("command-#{n}") end) |> Enum.map(fn {:ok, value} -> value end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, "revision_conflict"}, &1)) == 7
  end

  test "expiry is authoritative and replayed before accepting an answer" do
    {:ok, before} = InteractionStore.snapshot()
    {:ok, _} = create(%{"expires_at" => System.system_time(:millisecond) - 1})
    assert {:error, "revision_conflict"} = respond()
    assert {:ok, %{"state" => "expired"}} = InteractionStore.get("review-1")
    {:ok, events} = InteractionStore.events(before["cursor"])
    assert List.last(events)["data"]["state"] == "expired"
  end
end
