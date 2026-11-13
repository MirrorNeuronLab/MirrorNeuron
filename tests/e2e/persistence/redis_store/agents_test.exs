defmodule MirrorNeuron.Persistence.RedisStore.AgentsTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore

  test "agent observations are compacted before Redis persistence" do
    job_id = "redis-only-agent-snapshot-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "redis-only-agent-snapshot",
               "status" => "pending",
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    snapshot = %{
      "agent_id" => "worker",
      "current_state" => %{"phase" => "starting"},
      "last_heartbeat_at" => MirrorNeuron.Runtime.timestamp()
    }

    assert {:ok, observation} =
             RedisStore.persist_agent(job_id, "worker", snapshot, persist_disk?: false)

    assert observation["agent_id"] == "worker"
    refute Map.has_key?(observation, "current_state")
    assert {:ok, ^observation} = RedisStore.fetch_agent(job_id, "worker")

    RedisStore.delete_job(job_id)
  end

  test "agent observations discard local state and recovery payloads", %{
    namespace: namespace
  } do
    job_id = "compact-agent-summary-#{System.unique_integer([:positive])}"
    agent_id = "worker"

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "compact_agent_summary",
               "status" => "running",
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, _agent} =
             RedisStore.persist_agent(job_id, agent_id, %{
               "agent_id" => agent_id,
               "node_id" => agent_id,
               "agent_type" => "executor",
               "assigned_node" => "runtime@lab",
               "processed_messages" => 3,
               "mailbox_depth" => 0,
               "last_heartbeat_at" => MirrorNeuron.Runtime.timestamp(),
               "last_error" => nil,
               "sandbox" => %{"name" => "sandbox-1", "status" => "running"},
               "lease" => %{"lease_id" => "lease-1", "pool" => "default", "slots" => 1},
               "current_state" => %{
                 "runs" => 3,
                 "last_error" => nil,
                 "last_result" => %{
                   "sandbox_name" => "sandbox-1",
                   "lease" => %{"lease_id" => "lease-1", "pool" => "default", "slots" => 1}
                 },
                 "recovery_payload" => String.duplicate("x", 200_000)
               },
               "metadata" => %{
                 "paused" => false,
                 "backpressure" => %{"queue_depth" => 0},
                 "recovery_state" => String.duplicate("y", 200_000)
               }
             })

    assert {:ok, [summary]} = RedisStore.list_agent_summaries(job_id)
    assert summary["agent_id"] == agent_id
    assert summary["sandbox"]["name"] == "sandbox-1"
    assert summary["lease"]["lease_id"] == "lease-1"
    refute Map.has_key?(summary, "current_state")
    refute Map.has_key?(summary["metadata"], "recovery_state")

    assert {:ok, full_observation} = RedisStore.fetch_agent(job_id, agent_id)
    refute Map.has_key?(full_observation, "current_state")
    refute Map.has_key?(full_observation["metadata"], "recovery_state")

    full_key = redis_key(namespace, ["job", job_id, "agent", agent_id])
    summary_key = redis_key(namespace, ["job", job_id, "agent_summary", agent_id])
    assert {:ok, full_bytes} = Redix.command(MirrorNeuron.Redis.Connection, ["STRLEN", full_key])

    assert {:ok, summary_bytes} =
             Redix.command(MirrorNeuron.Redis.Connection, ["STRLEN", summary_key])

    assert full_bytes < 2_000
    assert summary_bytes == full_bytes

    RedisStore.delete_job(job_id)
  end
end
