defmodule MirrorNeuron.Grpc.RuntimeMembershipTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Grpc.RuntimeMembership

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        node: "runtime@test",
        drain: fn _ ->
          {:ok, %{"scheduling_eligible" => false, "drain" => %{"status" => "complete"}}}
        end,
        admission: fn -> {:ok, %{"reservations" => %{}, "queue" => [], "deferred" => []}} end,
        peers: fn -> [%{"node_name" => "peer@test"}] end,
        disconnect: fn node, peer -> send(self(), {:detached, node, peer}) end
      ],
      overrides
    )
  end

  test "only a fully drained, idle node can leave without stopping its runtime" do
    assert RuntimeMembership.detach(options()).status == 200
    assert_received {:detached, "runtime@test", "peer@test"}
  end

  test "an undrained node cannot be removed" do
    result =
      RuntimeMembership.detach(
        options(drain: fn _ -> {:ok, %{"scheduling_eligible" => true}} end)
      )

    assert result.status == 409
    assert Jason.decode!(result.error_json)["code"] == "MN_NODE_DRAIN_REQUIRED"
    refute_received {:detached, _, _}
  end

  test "reservations and both queues prevent removal even after drain completion" do
    for ledger <- [
          %{"reservations" => %{"run" => %{}}, "queue" => [], "deferred" => []},
          %{"reservations" => %{}, "queue" => [%{}], "deferred" => []},
          %{"reservations" => %{}, "queue" => [], "deferred" => [%{}]}
        ] do
      assert RuntimeMembership.detach(options(admission: fn -> {:ok, ledger} end)).status == 409
    end

    refute_received {:detached, _, _}
  end

  test "unavailable state fails closed" do
    assert RuntimeMembership.detach(options(admission: fn -> {:error, :unavailable} end)).status ==
             503

    refute_received {:detached, _, _}
  end
end
