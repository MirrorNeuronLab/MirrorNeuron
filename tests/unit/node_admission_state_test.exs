defmodule MirrorNeuron.Runtime.NodeAdmissionStateTest do
  use ExUnit.Case, async: true

  @moduletag :blueprint_runtime
  alias MirrorNeuron.Runtime.NodeAdmissionState, as: Admission

  defp holder(state),
    do: state["reservations"] |> Map.values() |> Enum.sort_by(& &1["generation"]) |> List.first()

  defp entry(id), do: %{"run_id" => id, "job_name" => id, "job_id" => "job-" <> id}

  defp submit(state, id) do
    {:ok, next, receipt} = Admission.transition(state, "submit", entry(id))
    {next, receipt}
  end

  test "one holder per PC, automatic FIFO, and independent PCs" do
    {a, first} = submit(Admission.new(), "a")
    assert first["state"] == "preparing"
    {a, second} = submit(a, "b")
    assert second["state"] == "queued"
    assert second["position"] == 1
    assert second["blocked_by"]["run_id"] == "a"
    {a, _} = submit(a, "c")
    {other, _} = submit(Admission.new(), "other-pc")
    assert holder(other)["run_id"] == "other-pc"
    {:ok, a, _} = Admission.transition(a, "release", %{"run_id" => "a", "generation" => 1})
    {a, d} = submit(a, "d")
    assert holder(a)["run_id"] == "b"
    assert d["position"] == 2
  end

  test "requests from several models reuse one run while other runs are denied" do
    {state, _} = submit(Admission.new(), "a")

    {:ok, state, _} =
      Admission.transition(state, "request_acquire", %{
        "generation" => 1,
        "run_id" => "a",
        "token" => "model-one"
      })

    {:ok, state, _} =
      Admission.transition(state, "request_acquire", %{
        "generation" => 1,
        "run_id" => "a",
        "token" => "model-two"
      })

    assert state["generation"] == 1

    assert {:error, :node_reserved} =
             Admission.transition(state, "request_acquire", %{"run_id" => "b", "token" => "other"})

    assert {:error, :node_reserved} =
             Admission.transition(state, "request_acquire", %{
               "run_id" => "",
               "token" => "unscoped"
             })

    assert {:error, :node_requests_active} =
             Admission.transition(state, "release", %{"run_id" => "a", "generation" => 1})
  end

  test "interactive requests drain before a new run acquires the PC" do
    {:ok, state, _} =
      Admission.transition(Admission.new(), "request_acquire", %{
        "run_id" => "",
        "token" => "interactive"
      })

    {state, queued} = submit(state, "a")
    assert queued["state"] == "queued"
    assert queued["blocked_by"]["job_name"] == "resource preparation or inference"
    assert holder(state)["claim_kind"] == "native_request"
    refute state["reservations"]["a"]
    {:ok, state, _} = Admission.transition(state, "request_release", %{"token" => "interactive"})
    {:ok, state, _} = Admission.transition(state, "promote", %{})
    assert holder(state)["run_id"] == "a"
  end

  test "unknown tokens cannot release real Runs and scoped replay returns its original allocation" do
    token = String.duplicate("a", 32)
    id = "request_" <> token
    {state, receipt} = submit(Admission.new(), id)
    assert {:ok, ^state, _} = Admission.transition(state, "request_release", %{"token" => token})

    assert {:error, :node_reserved} =
             Admission.transition(state, "request_acquire", %{"token" => token, "run_id" => ""})

    attrs = %{"token" => token, "run_id" => id, "generation" => receipt["generation"]}
    assert {:ok, acquired, response} = Admission.transition(state, "request_acquire", attrs)
    assert response["allocation"] == receipt["allocation"]
    assert {:ok, ^acquired, ^response} = Admission.transition(acquired, "request_acquire", attrs)

    for changed <- [%{"generation" => 0}, %{"run_id" => "different"}] do
      assert {:error, :stale_node_reservation} =
               Admission.transition(acquired, "request_acquire", Map.merge(attrs, changed))
    end

    assert {:ok, ^state, _} =
             Admission.transition(acquired, "request_release", %{"token" => token})
  end

  test "a persisted native claim migrates only with proof and never exposes the bearer token" do
    token = String.duplicate("f", 32)
    attrs = %{"token" => token, "run_id" => ""}
    {:ok, new, reply} = Admission.transition(Admission.new(), "request_acquire", attrs)
    [private] = Map.keys(new["reservations"])
    old = "request_" <> token
    legacy = new["reservations"][private] |> Map.put("run_id", old) |> Map.delete("claim_kind")
    encoded = %{new | "reservations" => %{old => legacy}} |> Jason.encode!() |> Jason.decode!()
    assert {:ok, migrated, ^reply} = Admission.transition(encoded, "request_acquire", attrs)
    assert Admission.allocations(migrated) == [reply["allocation"]]
    refute Jason.encode!(Admission.report(migrated)) =~ token
    assert {:ok, released, _} = Admission.transition(migrated, "request_release", attrs)
    assert released["reservations"] == %{}

    # An orphan still charges capacity but an unknown release cannot free it,
    # and a matching public Run cannot inherit its allocation.
    orphan = Map.put(encoded, "requests", %{})
    assert {:ok, charged, _} = Admission.transition(orphan, "request_release", attrs)
    assert Admission.allocations(charged) == [reply["allocation"]]
    refute Jason.encode!(Admission.report(charged)) =~ token

    assert {:error, :stale_node_reservation} =
             Admission.transition(charged, "request_acquire", attrs)

    {_queued, %{"state" => "queued"}} = submit(charged, old)

    # Old code could attach an unscoped token to the reservation of a real Run.
    ambiguous = put_in(encoded, ["reservations", old, "job_id"], "real-job")

    assert {:error, :stale_node_reservation} =
             Admission.transition(ambiguous, "request_acquire", attrs)

    assert {:ok, safe, _} = Admission.transition(ambiguous, "request_release", attrs)
    assert safe["reservations"][old] == ambiguous["reservations"][old]
  end

  test "receipt replay is idempotent, cancellation never cancels the holder" do
    {state, _} = submit(Admission.new(), "a")
    {state, _} = submit(state, "b")
    {again, receipt} = submit(state, "b")
    assert again == state
    assert receipt["position"] == 1

    assert {:error, :run_already_admitted} =
             Admission.transition(state, "cancel", %{"run_id" => "a"})

    {:ok, state, _} = Admission.transition(state, "cancel", %{"run_id" => "b"})
    assert state["queue"] == []
  end

  test "stale generations cannot release a reservation after restart" do
    {state, _} = submit(Admission.new(), "a")
    state = state |> Jason.encode!() |> Jason.decode!()

    assert {:error, :stale_node_reservation} =
             Admission.transition(state, "release", %{"run_id" => "a", "generation" => 0})

    assert {:error, :stale_node_reservation} =
             Admission.transition(state, "release", %{"run_id" => "other", "generation" => 1})
  end

  test "a finished or unknown run never receives a fabricated queued receipt" do
    {state, _} = submit(Admission.new(), "a")

    {:ok, state, _} =
      Admission.transition(state, "release", %{"run_id" => "a", "generation" => 1})

    assert Admission.receipt(state, "a")["state"] == "unreserved"
    assert Admission.receipt(state, "unknown")["state"] == "unreserved"
  end

  test "scheduling a queued start releases its claim until due, without blocking ready work" do
    {state, _} = submit(Admission.new(), "later")

    {:ok, state, receipt} =
      Admission.transition(state, "defer", %{
        "run_id" => "later",
        "not_before" => "2099-10-20T12:00:00Z"
      })

    assert receipt["not_before"] == "2099-10-20T12:00:00Z"
    {state, _} = submit(state, "ready")
    assert holder(state)["run_id"] == "ready"
    {again, _} = submit(state, "later")
    assert again == state
    {:ok, state, _} = Admission.transition(state, "cancel", %{"run_id" => "later"})
    assert state["deferred"] == []
  end

  test "legacy active and paused runs block new admission until confirmed cleanup" do
    {:ok, state, _} =
      Admission.transition(Admission.new(), "import", %{"runs" => ["paused", "distributed"]})

    {state, receipt} = submit(state, "new")
    assert receipt["state"] == "queued"
    {:ok, state, _} = Admission.transition(state, "release_legacy", %{"run_id" => "paused"})
    {:ok, state, _} = Admission.transition(state, "promote", %{})
    assert holder(state) == nil
    {:ok, state, _} = Admission.transition(state, "release_legacy", %{"run_id" => "distributed"})
    {:ok, state, _} = Admission.transition(state, "promote", %{})
    assert holder(state)["run_id"] == "new"
  end

  test "new arrivals cannot bypass an overdue scheduled start after a missed tick" do
    {state, _} = submit(Admission.new(), "due")

    {:ok, state, _} =
      Admission.transition(state, "defer", %{
        "run_id" => "due",
        "not_before" => "2000-01-01T00:00:00Z"
      })

    {state, arriving} = submit(state, "new")
    assert holder(state)["run_id"] == "due"
    assert arriving["state"] == "queued"
    assert arriving["position"] == 1
  end
end
