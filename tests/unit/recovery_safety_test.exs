defmodule MirrorNeuron.Runtime.RecoverySafetyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.RecoverySafety

  test "malformed checkpoint metadata requires manual inspection instead of raising" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "router", config: %{}}]}
    job = %{"status" => "running", "recovery_policy" => "local_restart"}

    agent = %{
      "agent_id" => "worker",
      "processed_messages" => 0,
      "mailbox_depth" => 0,
      "pending_messages" => [],
      "metadata" => "corrupt"
    }

    assert {:blocked, reason} = RecoverySafety.decision(job, manifest, [agent])
    assert reason =~ "checkpoints are corrupt"
  end

  test "well-formed checkpoint remains eligible for automatic recovery" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "router", config: %{}}]}
    job = %{"status" => "running", "recovery_policy" => "local_restart"}

    recovery_state = %{count: 1} |> :erlang.term_to_binary() |> Base.encode64()

    agent = %{
      "agent_id" => "worker",
      "processed_messages" => 1,
      "mailbox_depth" => 0,
      "pending_messages" => [],
      "inflight_message" => nil,
      "metadata" => %{"recovery_state" => recovery_state}
    }

    assert {:auto, _reason} = RecoverySafety.decision(job, manifest, [agent])
  end

  test "failed checkpoint without replayable work is blocked" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "executor", config: %{}}]}
    job = %{"status" => "running", "recovery_policy" => "local_restart"}

    recovery_state = %{last_error: "resource unavailable"} |> encode_checkpoint()

    agent = %{
      "agent_id" => "worker",
      "agent_type" => "executor",
      "current_state" => %{"last_error" => "resource unavailable"},
      "processed_messages" => 0,
      "mailbox_depth" => 0,
      "pending_messages" => [],
      "inflight_message" => nil,
      "metadata" => %{"recovery_state" => recovery_state}
    }

    assert {:blocked, reason} = RecoverySafety.decision(job, manifest, [agent])
    assert reason =~ "no replayable message"
  end

  test "failed checkpoint with a persisted restart action remains recoverable" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "executor", config: %{}}]}

    job = %{
      "status" => "running",
      "recovery_policy" => "local_restart",
      "policy_state" => %{
        "agents" => %{
          "worker" => %{
            "next_action" => "restart",
            "next_eligible_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      }
    }

    recovery_state = %{last_error: "resource unavailable"} |> encode_checkpoint()

    agent = %{
      "agent_id" => "worker",
      "agent_type" => "executor",
      "current_state" => %{"last_error" => "resource unavailable"},
      "processed_messages" => 0,
      "mailbox_depth" => 0,
      "pending_messages" => [],
      "inflight_message" => nil,
      "metadata" => %{"recovery_state" => recovery_state}
    }

    assert {:auto, _reason} = RecoverySafety.decision(job, manifest, [agent])
  end

  defp encode_checkpoint(state) do
    state |> :erlang.term_to_binary() |> Base.encode64()
  end
end
