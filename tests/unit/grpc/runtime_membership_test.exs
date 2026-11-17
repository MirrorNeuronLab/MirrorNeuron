defmodule MirrorNeuron.Grpc.RuntimeMembershipTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Grpc.RuntimeMembership

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        node: "runtime@test",
        verify_work: fn -> :ok end,
        admission: fn ->
          {:ok, %{"reservations" => %{}, "queue" => [], "deferred" => [], "requests" => %{}}}
        end,
        peers: fn -> [%{"node_name" => "peer@test"}] end,
        disconnect: fn node, peer ->
          send(self(), {:detached, node, peer})
          :ok
        end
      ],
      overrides
    )
  end

  test "an idle node can leave without a separate drain or stopping its runtime" do
    assert RuntimeMembership.detach(options()).status == 200
    assert_received {:detached, "runtime@test", "peer@test"}
  end

  test "active work missing from the admission ledger prevents removal" do
    result =
      RuntimeMembership.detach(
        options(verify_work: fn -> {:error, :missing_node_reservation} end)
      )

    assert result.status == 409
    assert Jason.decode!(result.error_json)["code"] == "MN_NODE_BUSY"
    refute_received {:detached, _, _}
  end

  test "reservations, queues and native requests prevent removal" do
    for ledger <- [
          %{"reservations" => %{"run" => %{}}},
          %{"queue" => [%{}]},
          %{"deferred" => [%{}]},
          %{"requests" => %{"request" => "run"}}
        ] do
      ledger = Map.merge(MirrorNeuron.Runtime.NodeAdmissionState.new(), ledger)
      assert RuntimeMembership.detach(options(admission: fn -> {:ok, ledger} end)).status == 409
    end

    refute_received {:detached, _, _}
  end

  test "unavailable state fails closed" do
    assert RuntimeMembership.detach(options(admission: fn -> {:error, :unavailable} end)).status ==
             503

    refute_received {:detached, _, _}
  end

  test "malformed admission state is unavailable, not idle" do
    assert RuntimeMembership.detach(options(admission: fn -> {:ok, %{}} end)).status == 503
    refute_received {:detached, _, _}
  end

  test "an unconfirmed disconnect never reports success" do
    result = RuntimeMembership.detach(options(disconnect: fn _, _ -> {:error, :unconfirmed} end))
    assert result.status == 503
    assert Jason.decode!(result.error_json)["code"] == "MN_NODE_REMOVAL_UNCONFIRMED"
  end

  test "an unavailable peer returns a safe retryable error" do
    result =
      RuntimeMembership.detach(
        options(
          disconnect: fn _, _ ->
            raise GRPC.RPCError,
              status: GRPC.Status.unavailable(),
              message: "private transport detail"
          end
        )
      )

    assert result.status == 503
    refute result.error_json =~ "private transport detail"
  end
end
