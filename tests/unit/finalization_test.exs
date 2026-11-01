defmodule MirrorNeuron.Runtime.FinalizationTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.Finalization

  test "a failed intent cannot publish or commit completion" do
    owner = self()

    assert {:error, :unavailable} =
             Finalization.commit("run", %{status: "running"}, terminal(), event(),
               persist: fn _, _ -> {:error, :unavailable} end,
               finish: fn _, _, _ -> send(owner, :committed) end,
               notify: fn _, _ -> send(owner, :published) end
             )

    refute_received :committed
    refute_received :published
  end

  test "a commit failure retains a serializable intent and never publishes success" do
    owner = self()

    assert {:error, :unavailable} =
             Finalization.commit("run", %{status: "running"}, terminal(), event(),
               persist: fn _, value ->
                 send(owner, {:intent, Jason.decode!(Jason.encode!(value))})
                 {:ok, value}
               end,
               finish: fn _, _, _ -> {:error, :unavailable} end,
               notify: fn _, _ -> send(owner, :published) end
             )

    assert_received {:intent, %{"status" => "running", "pending_finalization" => intent}}
    assert intent["terminal"]["status"] == "completed"
    assert is_binary(intent["event"]["event_id"])
    refute_received :published
  end

  test "successful finalization orders intent, commit and publication with a stable identity" do
    owner = self()

    options = [
      persist: fn _, job ->
        send(owner, :intent)
        {:ok, job}
      end,
      finish: fn _, job, event ->
        send(owner, {:commit, event.event_id})
        {:ok, job}
      end,
      notify: fn _, _ -> send(owner, :published) end
    ]

    for _ <- 1..2 do
      assert {:ok, _} =
               Finalization.commit("run", %{status: "running"}, terminal(), event(), options)
    end

    assert_receive :intent
    assert_receive {:commit, identity}
    assert_receive :published
    assert_receive :intent
    assert_receive {:commit, ^identity}
    assert_receive :published
  end

  defp terminal,
    do: %{status: "completed", attempt: 1, lease_epoch: 2, result_ref: %{"sha256" => "fixture"}}

  defp event, do: %{type: :job_completed, timestamp: "2026-10-31T00:00:00Z"}
end
