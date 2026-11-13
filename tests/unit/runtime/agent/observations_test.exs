defmodule MirrorNeuron.Runtime.AgentWorker.ObservationsTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.AgentWorker.Observations

  defp state(local_state) do
    %{
      job_id: "run-a",
      node: %{node_id: "worker", agent_type: "executor", role: "worker", config: %{}},
      local_state: local_state,
      paused?: false,
      runtime_context: %{lease_epoch: 4, lease_owner: "owner-a"},
      processed_messages: 7,
      mailbox_depth: 0,
      pressure_snapshot: nil
    }
  end

  test "observations expose only bounded runtime fields from private handler memory" do
    snapshot =
      state(%{
        private: %{token: "secret", pid: self()},
        last_error: nil,
        last_result: %{
          sandbox_name: "owned-sandbox",
          status: "ready",
          stdout: "private output",
          lease: %{lease_id: "lease-a", pool: "default", slots: 2, credentials: "secret"}
        }
      })
      |> Observations.snapshot(3)

    assert snapshot.lease == %{"lease_id" => "lease-a", "pool" => "default", "slots" => 2}
    assert snapshot.sandbox == %{"name" => "owned-sandbox", "status" => "ready"}
    assert snapshot.metadata["pending_message_count"] == 3
    assert snapshot.metadata["lease_epoch"] == 4
    assert snapshot.processed_messages == 7
    encoded = Jason.encode!(snapshot)
    refute encoded =~ "secret"
    refute encoded =~ "private output"
  end

  test "long multibyte errors stay within the byte bound and remain JSON encodable" do
    snapshot = state(%{last_error: String.duplicate("界", 4_000)}) |> Observations.snapshot(0)

    assert byte_size(snapshot.last_error) <= 8_192
    assert String.valid?(snapshot.last_error)
    assert {:ok, _} = Jason.encode(snapshot)
  end

  test "non-map local state does not leak into the monitoring projection" do
    snapshot = state({:private, self()}) |> Observations.snapshot(0)
    assert snapshot.last_error == nil
    assert snapshot.lease == %{}
    assert snapshot.sandbox == nil
    assert {:ok, _} = Jason.encode(snapshot)
  end

  test "invalid binary diagnostics are represented safely for JSON persistence" do
    snapshot = state(%{last_error: <<255, 254, 0>>}) |> Observations.snapshot(0)
    assert String.valid?(snapshot.last_error)
    assert {:ok, _} = Jason.encode(snapshot)
  end
end
