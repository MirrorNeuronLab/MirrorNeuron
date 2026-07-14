defmodule MirrorNeuron.Persistence.RedisIdentifierTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Persistence.RedisStore

  test "rejects map job identifiers before constructing Redis keys" do
    assert {:error, "job_id must be a non-empty string"} =
             RedisStore.persist_job(%{}, %{"status" => "pending"})

    assert {:error, "job_id must be a non-empty string"} = RedisStore.fetch_job(%{})

    assert {:error, "job_id must be a non-empty string"} =
             RedisStore.persist_terminal_job(%{}, %{"status" => "failed"})
  end
end
