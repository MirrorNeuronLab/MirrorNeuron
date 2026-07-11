defmodule MirrorNeuron.Persistence.DiskCheckpointTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.DiskCheckpoint

  setup do
    job_id = "disk-checkpoint-#{System.unique_integer([:positive])}"
    on_exit(fn -> DiskCheckpoint.delete_job(job_id) end)
    %{job_id: job_id}
  end

  test "atomically stores and loads job and agent recovery state", %{job_id: job_id} do
    job = %{
      "job_id" => job_id,
      "status" => "running",
      "updated_at" => "2026-07-10T10:00:00Z"
    }

    agent = %{
      "agent_id" => "stage/one",
      "current_state" => %{"count" => 2},
      "last_heartbeat_at" => "2026-07-10T10:00:01Z"
    }

    assert :ok = DiskCheckpoint.persist_job(job_id, job)
    assert :ok = DiskCheckpoint.persist_agent(job_id, "stage/one", agent)
    assert {:ok, ^job} = DiskCheckpoint.load_job(job_id)
    assert {:ok, [^agent]} = DiskCheckpoint.load_agents(job_id)

    assert {:ok, %{checkpoints: checkpoints, errors: []}} = DiskCheckpoint.list_jobs()
    assert Enum.any?(checkpoints, &(&1.job == job and &1.agents == [agent]))
  end

  test "prunes stale agents and removes all resources when the job is terminal", %{job_id: job_id} do
    assert :ok =
             DiskCheckpoint.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running"
             })

    assert :ok = DiskCheckpoint.persist_agent(job_id, "active", %{"agent_id" => "active"})
    assert :ok = DiskCheckpoint.persist_agent(job_id, "stale", %{"agent_id" => "stale"})
    assert :ok = DiskCheckpoint.prune_agents(job_id, ["active"])
    assert {:ok, [%{"agent_id" => "active"}]} = DiskCheckpoint.load_agents(job_id)

    assert :ok = DiskCheckpoint.delete_job(job_id)
    assert {:error, :enoent} = DiskCheckpoint.load_job(job_id)
    assert {:ok, []} = DiskCheckpoint.load_agents(job_id)
  end
end
