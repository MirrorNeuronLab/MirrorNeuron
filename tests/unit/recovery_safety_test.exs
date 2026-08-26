defmodule MirrorNeuron.Runtime.RecoverySafetyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.RecoverySafety

  test "agent observations never participate in clean-restart eligibility" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "router", config: %{}}]}
    job = %{"status" => "running", "recovery_policy" => "local_restart"}

    corrupt_retired_observation = %{
      "agent_id" => "worker",
      "metadata" => %{"recovery_state" => "not-base64"},
      "inflight_message" => %{"retired" => true}
    }

    assert {:auto, reason} =
             RecoverySafety.decision(job, manifest, [corrupt_retired_observation])

    assert reason =~ "clean job attempt"
  end

  test "retry-safe executor permits an automatic clean attempt" do
    manifest =
      %Manifest{
        nodes: [
          %{node_id: "worker", agent_type: "executor", config: %{"safe_to_retry" => true}}
        ]
      }

    job = %{"status" => "running", "recovery_policy" => "local_restart"}

    assert {:auto, _reason} = RecoverySafety.decision(job, manifest)
  end

  test "effectful node without a retry declaration requires operator approval" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "executor", config: %{}}]}
    job = %{"status" => "running", "recovery_policy" => "local_restart"}

    assert {:manual, reason} = RecoverySafety.decision(job, manifest)
    assert reason =~ "worker"
    assert reason =~ "do not declare retry safety"
  end

  test "manual recovery policy remains paused until approval" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "router", config: %{}}]}
    job = %{"status" => "running", "recovery_policy" => "manual_recover"}

    assert {:manual, reason} = RecoverySafety.decision(job, manifest)
    assert reason =~ "manual restart approval"
  end

  test "manual approval authorizes a clean attempt without restoring state" do
    manifest = %Manifest{nodes: [%{node_id: "worker", agent_type: "executor", config: %{}}]}
    job = %{"status" => "paused", "recovery_policy" => "manual_recover"}

    assert {:auto, reason} = RecoverySafety.decision(job, manifest, [], manual_resume: true)
    assert reason =~ "operator authorized"
  end
end
