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

  test "reports malformed checkpoints while their job directory still exists", %{job_id: job_id} do
    assert :ok = DiskCheckpoint.persist_job(job_id, %{"job_id" => job_id, "status" => "running"})
    assert :ok = DiskCheckpoint.persist_agent(job_id, "worker", %{"agent_id" => "worker"})

    encoded_job_id = Base.url_encode64(job_id, padding: false)

    [agent_path] =
      Path.wildcard(Path.join([DiskCheckpoint.root(), encoded_job_id, "agents", "*"]))

    File.write!(agent_path, "not-json")

    assert {:ok, %{errors: errors}} = DiskCheckpoint.list_jobs()

    assert Enum.any?(errors, fn
             {path, {_filename, _reason}} -> Path.basename(path) == encoded_job_id
             _error -> false
           end)
  end

  test "job locks serialize concurrent checkpoint transitions", %{job_id: job_id} do
    parent = self()

    holder =
      Task.async(fn ->
        DiskCheckpoint.with_job_lock(job_id, fn ->
          send(parent, :holder_acquired)

          receive do
            :release_holder -> :ok
          end
        end)
      end)

    assert_receive :holder_acquired

    waiter =
      Task.async(fn ->
        DiskCheckpoint.with_job_lock(job_id, fn -> send(parent, :waiter_acquired) end)
      end)

    refute_receive :waiter_acquired, 50
    send(holder.pid, :release_holder)
    assert :ok = Task.await(holder)
    assert :waiter_acquired = Task.await(waiter, 2_000)
    assert_receive :waiter_acquired
  end

  test "job locks release when their owner exits", %{job_id: job_id} do
    parent = self()

    holder =
      spawn(fn ->
        DiskCheckpoint.with_job_lock(job_id, fn ->
          send(parent, :holder_acquired)
          Process.sleep(:infinity)
        end)
      end)

    monitor = Process.monitor(holder)
    assert_receive :holder_acquired

    waiter =
      Task.async(fn ->
        DiskCheckpoint.with_job_lock(job_id, fn -> :waiter_acquired end)
      end)

    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}
    assert :waiter_acquired = Task.await(waiter, 2_000)
  end

  test "checkpoint scans wait for in-progress job transitions", %{job_id: job_id} do
    parent = self()

    holder =
      Task.async(fn ->
        DiskCheckpoint.with_job_lock(job_id, fn ->
          assert :ok =
                   DiskCheckpoint.persist_agent(job_id, "worker", %{"agent_id" => "worker"})

          send(parent, :partial_checkpoint_ready)

          receive do
            :finish_transition -> DiskCheckpoint.delete_job(job_id)
          end
        end)
      end)

    assert_receive :partial_checkpoint_ready

    scanner = Task.async(fn -> DiskCheckpoint.list_jobs() end)
    refute Task.yield(scanner, 50)

    send(holder.pid, :finish_transition)
    assert :ok = Task.await(holder)
    assert {:ok, %{errors: errors}} = Task.await(scanner, 2_000)

    encoded_job_id = Base.url_encode64(job_id, padding: false)
    refute Enum.any?(errors, fn {path, _reason} -> Path.basename(path) == encoded_job_id end)
  end
end
