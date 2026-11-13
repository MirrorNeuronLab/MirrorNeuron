defmodule MirrorNeuron.Persistence.RedisStore.RuntimeStatusTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Persistence.RedisStore.RuntimeStatus

  test "revision identity is stable across map insertion order and JSON round trips" do
    original = %{status: %{memory: 64, cpu: 2}, nodes: [%{id: "owner", healthy: true}]}
    decoded = Jason.decode!(Jason.encode!(original))

    assert RuntimeStatus.runtime_status_revision(original) ==
             RuntimeStatus.runtime_status_revision(decoded)
  end

  test "revision identity changes when values or list ordering change" do
    first = %{"records" => [%{"id" => "a"}, %{"id" => "b"}], "count" => 2}
    reordered = Map.update!(first, "records", &Enum.reverse/1)
    changed = put_in(first, ["count"], 3)

    refute RuntimeStatus.runtime_status_revision(first) ==
             RuntimeStatus.runtime_status_revision(reordered)

    refute RuntimeStatus.runtime_status_revision(first) ==
             RuntimeStatus.runtime_status_revision(changed)
  end
end
