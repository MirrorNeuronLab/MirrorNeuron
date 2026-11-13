defmodule MirrorNeuron.Runtime.ReliabilityPolicyTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.RuntimeTest.SafeRetryRunner

  test "omitted recovery policy persists auto request with local effective policy on a single node" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "auto_reliability_single_node_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{"ingress" => [%{"text" => "hello"}]},
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "done"}
        },
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "sink", "message_type" => "done"}
      ]
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job["status"] == "completed"
    assert job["requested_recovery_policy"] == "auto"
    assert job["recovery_policy"] == "local_restart"
    assert get_in(job, ["reliability", "mode"]) == "single_node"
    assert get_in(job, ["reliability", "effective_recovery_policy"]) == "local_restart"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "reliability_strategy_resolved"))

    RedisStore.delete_job(job_id)
  end

  test "explicit cluster recovery degrades to local restart on a single node and emits metadata" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cluster_reliability_degraded_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{"ingress" => [%{"text" => "hello"}]},
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "done"}
        },
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "sink", "message_type" => "done"}
      ],
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job["requested_recovery_policy"] == "cluster_recover"
    assert job["recovery_policy"] == "local_restart"
    assert job["reliability_degraded"] == true
    assert get_in(job, ["reliability", "degraded"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_reliability_degraded"))

    RedisStore.delete_job(job_id)
  end

  test "local recovery does not start a duplicate runner while an active lease exists" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "active_lease_recovery_guard_test",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "role" => "root_coordinator",
          "config" => %{"complete_after" => 1, "terminal_sink" => true, "complete_run" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "active-lease")
    {:ok, lease} = RedisStore.acquire_fenced_lease("job:#{job_id}", "other-runtime", 10_000)

    assert {:ok, %{action: :skipped, reason: "job lease is still active"}} =
             MirrorNeuron.recover_job(job_id)

    assert job_runner_pid(job_id, false) == nil
    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert is_nil(job["recovery_status"])

    RedisStore.release_fenced_lease("job:#{job_id}", "other-runtime", lease["epoch"])
    RedisStore.delete_job(job_id)
  end

  test "manual_recover policy pauses a safe unfinished run until the operator resumes it" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "manual_policy_recovery_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"value" => 99}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => config
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "manual_recover"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "manual-policy")

    assert {:ok, %{action: :paused_for_review, reason: reason}} =
             MirrorNeuron.recover_job(job_id)

    assert reason =~ "manual restart approval"
    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_requires_review"] == true
    assert get_in(job, ["recovery", "can_resume"]) == true

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, completed} = MirrorNeuron.wait_for_job(job_id, 3_000)
    assert completed["status"] == "completed"
    assert get_in(completed, ["result", "output", "payload", "value"]) == 99

    RedisStore.delete_job(job_id)
  end

  test "local recovery skips jobs whose effective policy is cluster recovery" do
    config = %{
      "runner_module" => SafeRetryRunner,
      "safe_to_retry" => true,
      "output_message_type" => nil
    }

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "cluster_policy_local_recovery_skip_test",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => config
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }

    {:ok, job_id} = persist_recoverable_job(manifest, "cluster-policy")

    assert {:ok, %{action: :skipped, reason: "job is configured for cluster recovery"}} =
             MirrorNeuron.recover_job(job_id)

    assert job_runner_pid(job_id, false) == nil

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    refute Map.has_key?(job, "recovery_status")

    RedisStore.delete_job(job_id)
  end
end
