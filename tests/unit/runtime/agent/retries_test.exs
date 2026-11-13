defmodule MirrorNeuron.Runtime.AgentWorker.RetriesTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.AgentWorker.Retries

  defp state do
    %{
      reclaim_deliveries?: false,
      delivery_group_ready?: false,
      next_delivery_reclaim_at_ms: System.monotonic_time(:millisecond) + 60_000,
      delivery_retries: %{}
    }
  end

  test "a later retry and a completed lease scan cannot postpone an earlier delivery" do
    next =
      state()
      |> Retries.schedule_delivery_reclaim({:ok, 0}, %{stream_id: "earlier"})
      |> Retries.schedule_delivery_reclaim({:ok, 60_000}, %{stream_id: "later"})
      |> Retries.mark_delivery_poll_succeeded(true)

    assert next.delivery_group_ready?
    assert Retries.delivery_reclaim_due?(next)
    assert next.delivery_retries["earlier"] < next.delivery_retries["later"]
  end

  test "settling one delivery retains every unrelated retry deadline" do
    next =
      state()
      |> Retries.schedule_delivery_reclaim({:ok, 0}, %{stream_id: "earlier"})
      |> Retries.schedule_delivery_reclaim({:ok, 60_000}, %{stream_id: "later"})

    retained = next.delivery_retries["later"]
    settled = Retries.forget_delivery_retry(next, %{stream_id: "earlier"})

    assert settled.delivery_retries == %{"later" => retained}
    refute Retries.delivery_reclaim_due?(settled)
  end

  test "a failed retry receipt cannot replace an already recorded deadline" do
    original = Retries.schedule_delivery_reclaim(state(), {:ok, 0}, %{stream_id: "pending"})

    for receipt <- [{:error, :not_owner}, {:ok, -1}, {:ok, "50"}, :no_retry] do
      assert Retries.schedule_delivery_reclaim(original, receipt, %{stream_id: "pending"}) ==
               original
    end
  end

  test "explicit recovery requests a lease scan even before the regular deadline" do
    original = state()
    refute Retries.delivery_reclaim_due?(original)
    assert Retries.delivery_reclaim_due?(%{original | reclaim_deliveries?: true})
  end
end
